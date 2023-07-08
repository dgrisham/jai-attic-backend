#import "Basic";
#import "String";
#import "http_server";
#import "jason";
#import "POSIX";
#import "System";
#import "File";
#import "File_Utilities";

main :: () {
    http_listen(port=9980);

    // log every request
    any("*", (request: *Request) { log("Have % request to %\n", request.method, request.path); });

    // automatically respond to OPTIONS preflight requests with 200 OK
    options("*", (request: *Request) {
        send_html(request, "", status_code=200);
    });

    get("/api/posts/by-author", (request: *Request) {
        push_allocator(temp);
        get_posts_by_author(request);
        reset_temporary_storage();
    }); // get posts grouped by author

    get("/api/posts/:id/draft-body", (request: *Request) {
        push_allocator(temp);
        get_draft_body(request);
        reset_temporary_storage();
    }); // get the draft markdeep body for this post
    post("/api/posts/:id/draft-body", (request: *Request) {
        push_allocator(temp);
        update_draft_body(request);
        reset_temporary_storage();
    }); // update draft body

    // get("/api/posts/:id/draft",      (request: *Request) {});
    // get("/api/posts/:id/published",  (request: *Request) {});

    post("/api/posts/:id/metadata",   (request: *Request) {
        push_allocator(temp);
        update_post_metadata(request);
        reset_temporary_storage();
    }); // update author/title/date

    while 1 sleep_milliseconds(60_000); // the program just exits instantly without this
}

cors_middleware :: (request: *Request) {
    // table_add(*request.headers, "Access-Control-Allow-Origin", "*");
    // table_add(*request.headers, "Access-Control-Allow-Methods", "POST");
    // table_add(*request.headers, "Access-Control-Allow-Headers", "Origin, Methods, Content-Type");

    // request.headers["Access-Control-Allow-Origin"] = "*";
    // request.headers["Access-Control-Allow-Methods"] = "POST";
    // request.headers["Access-Control-Allow-Headers"] = "Origin, Methods, Content-Type";
}

// POSTS_DIRECTORY :: "/usr/local/www/legacy/posts";
POSTS_DIRECTORY :: "/home/grish/scratch/attic-html/posts";
HTML_DIRECTORY :: "/home/grish/scratch/attic-html";

DB_FILE        :: "posts.db";
DB_BACKUP_FILE :: #run tprint("%.bak", DB_FILE);

using #import "Hash_Table";
operator []= :: (t: *Table(string, string), index: string, value: string) {;
    table_add(t, index, value);
}

Author :: struct {
    name: string;
    posts: *[..]Post;
};

Post :: struct {
    id:        int;
    author:    string;
    title:     string;
    date:      string;
}

get_posts_by_author :: (request: *Request) {
    posts := load_posts();
    if posts == null {
        log("Failed to load posts db");
        send_html(request, tprint("<pre>Failed to load posts db</pre>"), status_code=500);
        return;
    }

    authors: [..]Author;
    for post: <<posts {
        author_exists := false;
        for author: authors {
            if author.name == post.author {
                author_exists = true;
                array_add(author.posts, post);
            }
        }
        if !author_exists {
            author := New(Author);
            author.name = post.author;
            author.posts = New([..] Post);

            array_add(author.posts, post);
            array_add(*authors, author);
        }
    }

    result := json_write_string(authors);
    send_json(request, result);
}

load_posts :: () -> *[..] Post {
    #import "csv";

    get_member :: (name: string, index: int, x: *void) -> string {
        return name;
    }

    csv_data, success := read_entire_file(DB_FILE);
    if !success {
        log("Error reading file '%'", DB_FILE, flags=.ERROR);
        return null;
    }

    posts := New([..] Post);
    parse_success: bool;
    <<posts, parse_success = csv_parse(csv_data, Post, null, get_member);
    if !parse_success {
        log("Error parsing csv", flags=.ERROR);
        return null;
    }

    return posts;
}

get_draft_body :: (request: *Request) {
    draft: struct {
        data: string;
    }

    posts := load_posts();
    if posts == null {
        log("Failed to load posts db");
        send_html(request, tprint("<pre>Failed to load posts db</pre>"), status_code=500);
        return;
    }

    idStr, id_found := table_find(*request.params, "id");
    if !id_found {
        send_html(request, tprint("<pre>Missing id parameter</pre>"), status_code=400);
        return;
    }
    id, success := to_integer(idStr);
    if !success {
        send_html(request, tprint("<pre>ID should be in integer</pre>"), status_code=400);
        return;
    }

    found := false;
    for post: <<posts {
        if post.id == id {
            draft_data, success := read_entire_file(join(POSTS_DIRECTORY, tprint("%", post.id), "draft.md.html", separator="/"));
            if !success {
                log("Failed to read draft file for post ID %", id);
                send_html(request, tprint("<pre>Error reading post draft</pre>"), status_code=500);
                return;
            }

            draft.data = draft_data;
            found = true;
            break;
        }
    }
    if !found {
        send_html(request, tprint("<pre>post not found</pre>"), status_code=404);
        return;
    }

    result := json_write_string(draft);
    send_json(request, result);
}

update_post_metadata :: (request: *Request) {
    Post_Metadata :: struct {
        author: string;
        title: string;
        date: string;
    }

    log("Received request to update post metadata");

    posts := load_posts();
    if posts == null {
        log("Failed to load posts db");
        send_html(request, tprint("<pre>Failed to load posts db</pre>"), status_code=500);
        return;
    }

    idStr, id_found := table_find(*request.params, "id");
    if !id_found {
        log("Request is missing id parameter");
        send_html(request, tprint("<pre>Missing id parameter</pre>"), status_code=400);
        return;
    }
    id, success := to_integer(idStr);
    if !success {
        log("Failed to parse id as integer");
        send_html(request, tprint("<pre>id should be in integer</pre>"), status_code=400);
        return;
    }

    log("Attempting to update metadata for post %", id);

    found := false;
    for * post: <<posts {
        if post.id == id {
            post_metadata: Post_Metadata;
            success: bool;

            { // pull out the request body
                success, post_metadata = json_parse_string(request.body, Post_Metadata);
                if !success {
                    log("Failed to unmarshal json request body");
                    send_html(request, tprint("<pre>Failed to unmarshal json request body</pre>"), status_code=400);
                    return;
                }
            }

            post.author = post_metadata.author;
            post.title  = post_metadata.title;
            post.date   = post_metadata.date;

            found = true;
            break;
        }
    }

    if !found {
        log("Post not found for id %", id);
        send_html(request, tprint("<pre>post not found</pre>"), status_code=404);
        return;
    }

    if !write_posts_to_db(posts) {
        log("Failed to write updated posts to database");
        send_html(request, tprint("<pre>Error updating post metadata</pre>"), status_code=500);
        return;
    }

    log("Successfully updated metadata for post %", id);
    send_html(request, tprint("<pre>Successfuly updated post metadata</pre>"), status_code=200);
}

// overwrites the entire database file
write_posts_to_db :: (posts: *[..] Post) -> bool {
    #import "csv";

    builder: String_Builder;
    builder.allocator = temp;
    init_string_builder(*builder);
    defer reset(*builder);

    append(*builder, "id,author,title,date\n");

    for post: <<posts {
        append(*builder,
            join(
                tprint("%", post.id),
                csv_escape(post.author),
                csv_escape(post.title),
                post.date,
                separator=",",
            )
        );
        append(*builder, #char "\n");
    }

    // copy the current draft to the backup file
    if !copy_file(DB_FILE, DB_BACKUP_FILE) {
        log("Failed to backup database file before overwriting");
        return false;
    }

    // overwrite the current draft with the user's content
    if !write_entire_file(DB_FILE, *builder) {
        log("Failed to write updated post metadata to %", DB_FILE);
        // restore backup DB
        if !copy_file(DB_BACKUP_FILE, DB_FILE) {
            log("Failed to restore backup database after write failure");
        }
        return false;
    }

    return true;
}

update_draft_body :: (request: *Request) {
    Post_Draft_Body :: struct {
        data: string;
    }

    log("Have request to update post's draft body");

    posts := load_posts();
    if posts == null {
        log("Failed to load posts db");
        send_html(request, tprint("<pre>Failed to load posts db</pre>"), status_code=500);
        return;
    }

    idStr, id_found := table_find(*request.params, "id");
    if !id_found {
        send_html(request, tprint("<pre>Missing id parameter</pre>"), status_code=400);
        return;
    }
    id, success := to_integer(idStr);
    if !success {
        send_html(request, tprint("<pre>ID should be in integer</pre>"), status_code=400);
        return;
    }

    log("Attempting to update draft for post %", id);

    found := false;
    for post: <<posts {
        if post.id == id {
            new_draft: Post_Draft_Body;
            success: bool;

            { // pull out the request body
                success, new_draft = json_parse_string(request.body, Post_Draft_Body);
                if !success {
                    log("Failed to unmarshal json request body");
                    send_html(request, tprint("<pre>Failed to unmarshal json request body</pre>"), status_code=400);
                    return;
                }
            }

            draft_file := join(POSTS_DIRECTORY, tprint("%", post.id), "draft.md.html", separator="/");
            draft_backup_file := tprint("%.bak", draft_file);

            // copy the current draft to the backup file
            if !copy_file(draft_file, draft_backup_file) {
                log("Failed to backup draft file before overwriting (id %)", id);
                send_html(request, tprint("<pre>Error updating draft</pre>"), status_code=500);
                return;
            }

            // overwrite the current draft with the user's content
            if !write_entire_file(draft_file, new_draft.data) {
                log("Failed to update draft for post id %", id);
                // restore backup DB
                if !copy_file(draft_backup_file, draft_file) {
                    log("Failed to restore backup database after write failure");
                }
                send_html(request, tprint("<pre>Error updating draft</pre>"), status_code=500);
                return;
            }

            found = true;
            break;
        }
    }

    if !found {
        send_html(request, tprint("<pre>Post id not found</pre>"), status_code=404);
        return;
    }

    log("Successfully updated draft for post %", id);
    send_html(request, tprint("<pre>Successfully updated draft</pre>"), status_code=200);
}

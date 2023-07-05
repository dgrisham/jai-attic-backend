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
    any("*", (request: *Request) { print("Have request to %\n", request.path); });

    get("/api/posts/by-author", (request: *Request) {
        push_allocator(temp);
        get_posts_by_author(request);
        reset_temporary_storage();
    }); // get posts grouped by author

    get("/api/posts/:id/draft_body", (request: *Request) {
        push_allocator(temp);
        get_draft_body(request);
        reset_temporary_storage();
    }); // get the draft markdeep body for this post
    post("/api/posts/:id/draft_body", (request: *Request) {
        push_allocator(temp);
        update_draft_body(request);
        reset_temporary_storage();
    }); // update draft body

    get("/api/posts/:id/draft",      (request: *Request) {});
    get("/api/posts/:id/published",  (request: *Request) {});

    post("/api/posts/:id/title",      (request: *Request) {}); // update title
    post("/api/posts/:id/date",       (request: *Request) {}); // update date
    post("/api/publish/:id",          (request: *Request) {}); // draft body becomes published body

    // get("/api/posts/:author/:date/:filename", (request: *Request) {
    //     get_post(request);
    // });

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

// Authors :: Table(string, *[..]Post);

Author :: struct {
    name: string;
    posts: *[..]Post;
};

Post :: struct {
    id:     int;
    author: string;
    title:  string;
    date:   string;
    post:   string;
    draft:  string;
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

DB_FILE :: "posts.db";

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

// overwrites the entire database file
// write_posts_to_db :: (posts: *[..] Post) -> bool {
//     #import "csv";

//     builder: String_Builder;
//     builder.allocator = temp;
//     init_string_builder(*builder);

//     for post: <<posts {
//         append(builder, post.id);
//     }

//     return posts;
// }

// Post :: struct {
//     id:     int;
//     author: string;
//     title:  string;
//     date:   string;
//     post:   string;
//     draft:  string;
// }

// POSTS_DIRECTORY :: "/usr/local/www/legacy/posts";
POSTS_DIRECTORY :: "/home/grish/scratch/attic-html/posts";
HTML_DIRECTORY :: "/home/grish/scratch/attic-html";

using #import "Hash_Table";
operator []= :: (t: *Table(string, string), index: string, value: string) {;
    table_add(t, index, value);
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
            draft_data, success := read_entire_file(join(POSTS_DIRECTORY, post.draft, separator="/"));
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
    // table_reset(*request.params); // TODO: seems like things break without this, should be in the lib though
}

// update_post_metadata :: (request: *Request) {
//     post_metadata: struct {
//         author: string;
//         title: string;
//         date: string;
//     }

//     posts := load_posts();
//     if posts == null {
//         // TODO
//     }

//     idStr, id_found := table_find(*request.params, "id");
//     if !id_found {
//         send_html(request, tprint("<pre>Missing id parameter</pre>"), status_code=400);
//         return;
//     }
//     id, success := to_integer(idStr);
//     if !success {
//         send_html(request, tprint("<pre>id should be in integer</pre>"), status_code=400);
//         return;
//     }

//     found := false;
//     for post: <<posts {
//         if post.id == id {
//             found = true;
//             break;
//         }
//     }
//     if !found {
//         send_html(request, tprint("<pre>post not found</pre>"), status_code=404);
//         return;
//     }

//     result := json_write_string(draft);
//     send_json(request, result);
//     // table_reset(*request.params); // TODO: seems like things break without this, should be in the lib though
// }

update_draft_body :: (request: *Request) {
    Post_Draft_Body :: struct {
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
            new_draft: Post_Draft_Body;
            success: bool;

            { // pull out the request body
                success, new_draft = json_parse_string(request.body, Post_Draft_Body);
                if !success {
                    log("Failed to unmarshal json request body", id);
                    send_html(request, tprint("<pre>Failed to unmarshal json request body</pre>"), status_code=400);
                    return;
                }
            }

            draft_file := join(POSTS_DIRECTORY, post.draft, separator="/");
            draft_backup_file := tprint("%.bak", draft_file);

            { // copy the current draft to the backup file
                success := copy_file(draft_file, draft_backup_file);
                if !success {
                    log("Failed to backup draft file before overwriting (id %)", id);
                    send_html(request, tprint("<pre>Error updating draft</pre>"), status_code=500);
                    return;
                }
            }

            { // overwrite the current draft with the user's content
                success := write_entire_file(draft_file, new_draft.data);
                if !success {
                    log("Failed to update draft for post id %", id);
                    send_html(request, tprint("<pre>Error updating draft</pre>"), status_code=500);
                    return;
                }
            }

            found = true;
            break;
        }
    }

    if !found {
        send_html(request, tprint("<pre>Post id not found</pre>"), status_code=404);
        return;
    }
    send_html(request, tprint("<pre>Successfully updated draft</pre>"), status_code=200);
}

// get_post :: (request: *Request) {
//     postBody: struct {
//         data: string;
//     }

//     author, author_found := table_find(*request.params, "author");
//     if !author_found {
//         send_html(request, tprint("<pre>Missing author parameter</pre>"), status_code=400);
//         return;
//     }
//     log("author: %", author);

//     date, date_found := table_find(*request.params, "date");
//     if !date_found {
//         send_html(request, tprint("<pre>Missing date parameter</pre>"), status_code=400);
//         return;
//     }
//     log("date: %", date);

//     filename, filename_found := table_find(*request.params, "filename");
//     if !filename_found {
//         send_html(request, tprint("<pre>Missing filename parameter</pre>"), status_code=400);
//         return;
//     }
//     log("filename: %", filename);

//     path := replace(join(POSTS_DIRECTORY, author, date, filename, separator="/"), "%20", " ");
//     defer free(path);

//     log("path: %", path);
//     body, success := get_post_body(path);
//     if !success {
//         send_html(request, tprint("<pre>Post not found</pre>"), status_code=404);
//         return;
//     }

//     postBody.data = body;
//     result := json_write_string(postBody);
//     send_json(request, result);
//     // table_reset(*request.params); // TODO: seems like things break without this, should be in the lib though
//     reset_temporary_storage();
// }

update_post :: (request: *Request) {

    // load_posts

    author, author_found := table_find(*request.params, "author");
    if !author_found {
        send_html(request, tprint("<pre>Missing author parameter</pre>"), status_code=400);
        return;
    }

    date, date_found := table_find(*request.params, "date");
    if !date_found {
        send_html(request, tprint("<pre>Missing date parameter</pre>"), status_code=400);
        return;
    }

    filename, filename_found := table_find(*request.params, "filename");
    if !filename_found {
        send_html(request, tprint("<pre>Missing filename parameter</pre>"), status_code=400);
        return;
    }

    log(request.body);
}

parse_post_title :: (path: string) -> string, bool {

    title: string = ---;
    post_data, success := read_entire_file(path);
    if !success {
        log("Failed to read post file %", post_data);
        return title, false;
    }

    title_left := find_index_from_left(post_data, "<title>");
    if title_left == -1 {
        log("Failed to parse title from post at path %", path);
        return title, false;
    }
    title_left += 7; // offset the <title>

    title_right := find_index_from_left(post_data, "</title>", title_left);
    if title_right == -1 {
        log("Failed to parse title from post at path %", path);
        return title, false;
    }

    builder: String_Builder;
    builder.allocator = temp;
    init_string_builder(*builder);

    for title_left..title_right-1 {
        append(*builder, post_data[it]);
    }
    title = builder_to_string(*builder);
    reset(*builder);

    return title, true;
}

get_post_body :: (path: string) -> string, bool {

    body: string = ---;
    post_data, success := read_entire_file(path);
    if !success {
        log("Failed to read post file %", post_data);
        return body, false;
    }


    LEFT_TAG  :: #string END
<div class="pure-u-1 pure-u-xl-1-3 post-body">
END

    RIGHT_TAG :: #string END

</div>
<div class="pure-u-1 pure-u-xl-1-3"></div>
END

    body_left := find_index_from_left(post_data, LEFT_TAG);
    if body_left == -1 {
        log("Failed to parse left body tag from post at path %", path);
        return body, false;
    }
    body_left += LEFT_TAG.count;

    body_right := find_index_from_left(post_data, RIGHT_TAG, body_left);
    if body_right == -1 {
        log("Failed to parse right body tag from post at path %", path);
        return body, false;
    }

    builder: String_Builder;
    init_string_builder(*builder);

    for body_left..body_right-1 {
        append(*builder, post_data[it]);
    }
    body = builder_to_string(*builder);
    reset(*builder);

    return body, true;
}

get_post_paths :: () -> []Path #must {

    new_context: Context;
    new_context.allocator = temp;

    push_context new_context {
        paths: [..]Path;

        visitor :: (info: *File_Visit_Info_With_Depth, paths: *[..] Path) {
            if info.depth == 2 {
                if info.short_name == "post.html" {
                    array_add(paths, parse_path(info.full_name, reduce=true));
                } else if info.is_directory {
                    info.descend_into_directory = false;
                }
            }
        }

        visit_files_with_depth(POSTS_DIRECTORY, recursive=true, *paths, visitor, follow_symlinks=true);

        return paths;
    }
}

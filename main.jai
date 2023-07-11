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

    get("/api/posts/:id/draft-preview", (request: *Request) {
        push_allocator(temp);
        get_draft_preview(request);
        reset_temporary_storage();
    }); // generate a preview for this post's current draft

    post("/api/posts/:id/publish", (request: *Request) {
        push_allocator(temp);
        publish_draft(request);
        reset_temporary_storage();
    }); // publish the most recent draft

    // get("/api/posts/:id/draft",      (request: *Request) {});
    // get("/api/posts/:id/published",  (request: *Request) {});

    post("/api/posts/:id/metadata", (request: *Request) {
        push_allocator(temp);
        update_post_metadata(request);
        reset_temporary_storage();
    }); // update author/title/date

    post("/api/posts/:id/cover", (request: *Request) {
        push_allocator(temp);
        update_post_cover(request);
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
    date:      string;
    title:     string;
    live:      bool;
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

publish_draft :: (request: *Request) {
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
            post_file := join(POSTS_DIRECTORY, tprint("%", post.id), "post.html", separator="/");
            post_backup_file := tprint("%.bak", post_file);

            // copy the current post to the backup file
            if !copy_file(post_file, post_backup_file) {
                log("Failed to backup post file before overwriting (id %)", id);
                send_html(request, tprint("<pre>Error publish post</pre>"), status_code=500);
                return;
            }

            new_post: string;
            {
                draft_data, load_draft_success := read_entire_file(join(POSTS_DIRECTORY, tprint("%", post.id), "draft.md.html", separator="/"));
                if !load_draft_success {
                    log("Failed to read draft file for post ID %", id);
                    send_html(request, tprint("<pre>Error reading post draft</pre>"), status_code=500);
                    return;
                }

                template_data, load_template_success := read_entire_file("post-template.html");
                if !load_template_success {
                    log("Failed to lost post template file for id %", id);
                    send_html(request, tprint("<pre>Error reading post template</pre>"), status_code=500);
                    return;
                }

                new_post = replace(replace(template_data, "{{BODY}}", draft_data), "{{TITLE}}", post.title);
            }

            // overwrite the current published post
            if !write_entire_file(post_file, new_post) {
                log("Failed to write updated post for id %", id);
                // restore backup DB
                if !copy_file(post_backup_file, post_file) {
                    log("Failed to restore backup post after write failure");
                }
                send_html(request, tprint("<pre>Error publishing post</pre>"), status_code=500);
                return;
            }

            found = true;
            break;
        }
    }
    if !found {
        send_html(request, tprint("<pre>post not found</pre>"), status_code=404);
        return;
    }

    send_html(request, "");
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

get_draft_preview :: (request: *Request) {
    preview: string;

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
            draft_data: string;
            success: bool;
            {
                draft_data, success = read_entire_file(join(POSTS_DIRECTORY, tprint("%", post.id), "draft.md.html", separator="/"));
                if !success {
                    log("Failed to read draft file for post ID %", id);
                    send_html(request, tprint("<pre>Error reading post draft</pre>"), status_code=500);
                    return;
                }
            }

            template_data: string;
            {
                template_data, success = read_entire_file("post-template.html");
                if !success {
                    log("Failed to lost post template file for id %", id);
                    send_html(request, tprint("<pre>Error reading post template</pre>"), status_code=500);
                    return;
                }
            }

            preview = replace(replace(template_data, "{{BODY}}", draft_data), "{{TITLE}}", post.title);
            found = true;
            break;
        }
    }
    if !found {
        send_html(request, tprint("<pre>post not found</pre>"), status_code=404);
        return;
    }

    send_html(request, preview);
}

update_post_metadata :: (request: *Request) {
    Post_Metadata :: struct {
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

    append(*builder, "id,author,date,title,live\n");

    for post: <<posts {
        append(*builder,
            join(
                tprint("%", post.id),
                csv_escape(post.author),
                post.date,
                csv_escape(post.title),
                tprint("%", post.live),
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
            // pull out the request body
            success, new_draft := json_parse_string(request.body, Post_Draft_Body);
            if !success {
                log("Failed to unmarshal json request body");
                send_html(request, tprint("<pre>Failed to unmarshal json request body</pre>"), status_code=400);
                return;
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
                    log("Failed to restore backup draft after write failure");
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

update_post_cover :: (request: *Request) {
    log("Have request to update post's cover");

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

    log("Attempting to update cover for post %", id);

    found := false;
    for post: <<posts {
        if post.id == id {

            // parse the multipart/form-data boundary from the content-type
            // e.g.
            // content-type : multipart/form-data; boundary=WebKitFormBoundaryrobaEexalWqdIGJ5
            boundary: string;
            content_type_found := false;
            for v, k: request.headers {
                if equal_nocase(k, "content-type") {
                    if !begins_with(v, "multipart/form-data") {
                        log("Invalid content-type: expected 'multipart/form-data[...]', got '%'", v);
                        send_html(request, tprint("<pre>Unexpected content-type</pre>"), status_code=400);
                        return;
                    }

                    boundary_string :: "boundary=";
                    left := find_index_from_left(v, boundary_string);
                    if left == -1 {
                        log("Missing multipart/form-data boundary in content-type header: '%'", v);
                        send_html(request, tprint("<pre>Missing multipart/form-data boundary in content-type header</pre>"), status_code=400);
                        return;
                    }

                    offset := left + boundary_string.count;
                    boundary = tprint("--%", slice(v, offset, v.count - offset));
                    content_type_found = true;
                    break;
                }
            }
            if !content_type_found {
                log("Missing content-type header");
                send_html(request, tprint("<pre>Missing content-type header</pre>"), status_code=400);
                return;
            }

            // here we parse out the image data very simply by assuming the request contains a single file
            // (the content-type should be multipart/mixed if it's multiple files, (see https://www.rfc-editor.org/rfc/rfc2388#section-4.2),
            // but we don't check that explicitly anyway).
            // the boundary is specified in the content-type (parsed above), then in the request.body we
            // should see the boundary preceded by two dashes --, then metadata describing the file, followed
            // by \r\n\r\n, then the actual file data, and finally the boundary again but this time preceded
            // and succeeded by two dashes (and \r\n I think, but we don't really care about that)
            // e.g.
            // ```
            // --WebKitFormBoundary1YbeMR7tQ6Eoy59B
            // Content-Disposition: form-data; name="file"; filename="melting-face-statue-matte.jpg"
            // Content-Type: image/jpeg
            //
            // <data>
            // --WebKitFormBoundary1YbeMR7tQ6Eoy59B--
            //
            // ```
            // to make this even simpler, instead of looking for the boundary/metadata we just look for the
            // first instance of \r\n in the request body, then assuming everything until the rightmost
            // boundary is the file contents.
            //
            // https://www.rfc-editor.org/rfc/rfc1867
            // https://stackoverflow.com/a/3508291

            start := find_index_from_left(request.body, "\r\n\r\n");
            if start == -1 || start + 4 >= request.body.count {
                log("Failed to locate form data");
                send_html(request, tprint("<pre>Failed to extract cover image data</pre>"), status_code=400);
                return;
            }
            start += 4; // account for the \r\n\r\n

            end := find_index_from_right(request.body, tprint("\r\n%--", boundary));
            if end == -1 {
                log("Failed to locate rightmost boundary for form data");
                send_html(request, tprint("<pre>Failed to extract cover image data</pre>"), status_code=400);
                return;
            }

            /* boundaries found, save the cover data part to a file */

            path := tprint("/tmp/attic/covers/%", id);
            if !make_directory_if_it_does_not_exist(path) {
                log("Failed to create directory to save cover image in '%'", path);
                send_html(request, tprint("<pre>Error saving cover image</pre>"), status_code=500);
                return;
            }

            image := request.body;
            image.data += start;
            image.count = end - start;
            if !write_entire_file(tprint("%/original", path), image) {
                log("Failed to save cover image for post %", id);
                send_html(request, tprint("<pre>Error saving cover image</pre>"), status_code=500);
                return;
            }

            {
                jobs := load_thumbnail_queue();
                found := false;
                for * job: <<jobs {
                    if job.id == id {
                        job.title = post.title;
                        job.author = post.author;
                        job.state = "READY";
                        job.error_reason = "";
                        found = true;
                        break;
                    }
                }
                if !found { // job not found, append to the array
                    array_add(jobs, Thumbnail_Job.{
                        post.id,
                        post.title,
                        post.author,
                        "READY",
                        "",
                    });
                }
                if !write_thumbnail_jobs_to_db(jobs) {
                    log("Failed to add thumbnail job to queue for post id '%'", id);
                    send_html(request, tprint("<pre>Error updating thumbnail</pre>"), status_code=500);
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

    log("Successfully uploaded cover image for post %", id);
    send_html(request, tprint("<pre>Successfully uploaded cover image</pre>"), status_code=200);
}

Thumbnail_Job :: struct {
    id:           int;
    title:        string;
    author:       string;
    state:        string;
    error_reason: string;
}

THUMBNAIL_QUEUE_DB_FILE :: "thumbnail_creation_queue.db";
THUMBNAIL_QUEUE_DB_BACKUP_FILE :: #run tprint("%.bak", THUMBNAIL_QUEUE_DB_FILE);

load_thumbnail_queue :: () -> *[..] Thumbnail_Job {
    #import "csv";

    get_member :: (name: string, index: int, x: *void) -> string {
        return name;
    }

    csv_data, success := read_entire_file(THUMBNAIL_QUEUE_DB_FILE);
    if !success {
        log("Error reading file '%'", THUMBNAIL_QUEUE_DB_FILE, flags=.ERROR);
        return null;
    }

    jobs := New([..] Thumbnail_Job);
    parse_success: bool;
    <<jobs, parse_success = csv_parse(csv_data, Thumbnail_Job, null, get_member);
    if !parse_success {
        log("Error parsing csv", flags=.ERROR);
        return null;
    }

    return jobs;
}

write_thumbnail_jobs_to_db :: (jobs: *[..] Thumbnail_Job) -> bool {
    #import "csv";

    builder: String_Builder;
    builder.allocator = temp;
    init_string_builder(*builder);
    defer reset(*builder);

    append(*builder, "id,title,author,state,error_reason\n");

    for job: <<jobs {
        append(*builder,
            join(
                tprint("%", job.id),
                csv_escape(job.title),
                csv_escape(job.author),
                job.state,
                csv_escape(job.error_reason),
                separator=",",
            )
        );
        append(*builder, #char "\n");
    }

    // copy the current draft to the backup file
    if !copy_file(THUMBNAIL_QUEUE_DB_FILE, THUMBNAIL_QUEUE_DB_BACKUP_FILE) {
        log("Failed to backup database file before overwriting");
        return false;
    }

    // overwrite the current draft with the user's content
    if !write_entire_file(THUMBNAIL_QUEUE_DB_FILE, *builder) {
        log("Failed to write updated thumbnail jobs to %", THUMBNAIL_QUEUE_DB_FILE);
        // restore backup DB
        if !copy_file(THUMBNAIL_QUEUE_DB_BACKUP_FILE, THUMBNAIL_QUEUE_DB_FILE) {
            log("Failed to restore backup database after write failure");
        }
        return false;
    }

    return true;
}

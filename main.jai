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

    post("/api/regenerate-homepage", (request: *Request) {
        push_allocator(temp);
        regenerate_homepage(null);
        reset_temporary_storage();
    });

    post("/api/posts", (request: *Request) {
        push_allocator(temp);
        create_post(request);
        reset_temporary_storage();
    }); // create new post
    get("/api/posts/by-author", (request: *Request) {
        push_allocator(temp);
        get_posts_by_author(request);
        reset_temporary_storage();
    }); // get posts grouped by author
    // delete("/api/posts/:id", (request: *Request) {
    //     push_allocator(temp);
    //     delete_post(request);
    //     reset_temporary_storage();
    // }); // TODO delete post

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

    get("/api/posts/:id/published", (request: *Request) {
        push_allocator(temp);
        get_published_post(request);
        reset_temporary_storage();
    }); // generate published post

    post("/api/posts/:id/publish", (request: *Request) {
        push_allocator(temp);
        publish_draft(request);
        reset_temporary_storage();
    }); // publish the most recent draft

    post("/api/posts/:id/metadata", (request: *Request) {
        push_allocator(temp);
        update_post_metadata(request);
        reset_temporary_storage();
    }); // update title/date

    get("/api/posts/:id/thumbnail-status", (request: *Request) {
        push_allocator(temp);
        get_thumbnail_creation_status(request);
        reset_temporary_storage();
    }); // get thumbnail creation status for last uploaded cover image
    post("/api/posts/:id/cover", (request: *Request) {
        push_allocator(temp);
        update_post_cover(request);
        reset_temporary_storage();
    }); // upload post cover image

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
    name  : string;
    posts : *[..]Post;
};

Post :: struct {
    id        : int;
    author    : string;
    date      : string;
    title     : string;
    is_public : bool;
}

create_post:: (request: *Request) {
    New_Post :: struct {
        author : string;
        title  : string;
    }

    success, new_post_data := json_parse_string(request.body, New_Post);
    if !success {
        log("Failed to unmarshal json request body");
        send_html(request, tprint("<pre>Failed to unmarshal json request body</pre>"), status_code=400);
        return;
    }

    if new_post_data.author == "" {
        log("Missing author for new post");
        send_html(request, tprint("<pre>Missing author for new post</pre>"), status_code=400);
        return;
    }
    if new_post_data.title == "" {
        log("Missing title for new post");
        send_html(request, tprint("<pre>Missing title for new post</pre>"), status_code=400);
        return;
    }

    posts := load_posts();
    if posts == null {
        log("Failed to load posts db");
        send_html(request, tprint("<pre>Failed to load posts db</pre>"), status_code=500);
        return;
    }

    max_id: int = 0;
    for post: <<posts {
        max_id = max(max_id, post.id);
    }
    id := max_id + 1;

    new_post := Post.{
        id        = id,
        author    = new_post_data.author,
        title     = new_post_data.title,
        is_public = false,
    };
    array_add(posts, new_post);

    if !write_posts_to_db(posts) {
        log("Failed to write updated posts array to database after adding new post");
        send_html(request, tprint("<pre>Error adding post</pre>"), status_code=500);
        return;
    }

    post_directory := join(POSTS_DIRECTORY, tprint("%", id), separator="/");
    if !make_directory_if_it_does_not_exist(post_directory, recursive=false) {
        log("Failed to create directory for new post at '%'", post_directory);
        send_html(request, tprint("<pre>Error creating post</pre>"), status_code=500);
        return;
    }

    draft_file := join(post_directory, "draft.md.html", separator="/");
    if !write_entire_file(draft_file, tprint("# %\n\n", new_post.title)) {
        log("Failed to create draft file for new post with id %", id);
        send_html(request, tprint("<pre>Error creating post</pre>"), status_code=500);
        return;
    }

    result := json_write_string(new_post);
    send_json(request, result);
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

get_published_post :: (request: *Request) {
    generated_post: string;

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
            post_body: string;
            success: bool;
            {
                post_body, success = read_entire_file(join(POSTS_DIRECTORY, tprint("%", post.id), "published.md.html", separator="/"));
                if !success {
                    log("Failed to read published post body file for post ID %", id);
                    send_html(request, tprint("<pre>Error reading published post body</pre>"), status_code=500);
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

            current_time :: inline () -> u64 {
                return cast(u64)to_microseconds(current_time_monotonic());
            }
            // COVER_IMAGE_RANDOM_NUMBER is just to set a random query var so the browser requests the image each time the post generated (since it might've changed)
            generated_post = replace(replace(replace(template_data, "{{BODY}}", post_body), "{{TITLE}}", post.title), "{{COVER_IMAGE_RANDOM_NUMBER}}", tprint("%", current_time()));

            found = true;
            break;
        }
    }
    if !found {
        send_html(request, tprint("<pre>post not found</pre>"), status_code=404);
        return;
    }

    send_html(request, generated_post);
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
            published_file := join(POSTS_DIRECTORY, tprint("%", post.id), "published.md.html", separator="/");
            published_backup_file := tprint("%.bak", published_file);

            if file_exists(published_file) {
                // copy the current post to the backup file
                if !copy_file(published_file, published_backup_file) {
                    log("Failed to backup published post file before overwriting (id %)", id);
                    send_html(request, tprint("<pre>Error publishing post</pre>"), status_code=500);
                    return;
                }
            }

            draft_file := join(POSTS_DIRECTORY, tprint("%", post.id), "draft.md.html", separator="/");

            // copy the current post to the backup file
            if !copy_file(draft_file, published_file) {
                log("Failed to copy draft file to published file (id %)", id);
                // restore backup post
                if !copy_file(published_backup_file, published_file) {
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

            current_time :: inline () -> u64 {
                return cast(u64)to_microseconds(current_time_monotonic());
            }
            // COVER_IMAGE_RANDOM_NUMBER is just to set a random query var so the browser requests the image whenever a new preview is generated (because it might've changed)
            preview = replace(replace(replace(template_data, "{{BODY}}", draft_data), "{{TITLE}}", post.title), "{{COVER_IMAGE_RANDOM_NUMBER}}", tprint("%", current_time()));

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
        title     : string;
        author    : string;
        date      : string;
        is_public : bool;
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

    should_regenerate_homepage := false;
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

            should_regenerate_thumbnail := post.title != post_metadata.title || post.author != post_metadata.author;
            should_regenerate_homepage   = should_regenerate_thumbnail || post.is_public != post_metadata.is_public;

            post.title     = post_metadata.title;
            post.author    = post_metadata.author;
            post.date      = post_metadata.date;
            post.is_public = post_metadata.is_public;

            if should_regenerate_thumbnail { // regenerate the post thumbnails if the metadata changed
                jobs := load_thumbnail_queue();
                found := false;
                for * job: <<jobs {
                    if job.id == id {
                        job.title              = post.title;
                        job.author             = post.author;
                        job.state              = "READY";
                        job.error_reason       = "";
                        job.use_existing_cover = true;

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
                        false,
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
        log("Post not found for id %", id);
        send_html(request, tprint("<pre>post not found</pre>"), status_code=404);
        return;
    }

    if !write_posts_to_db(posts) {
        log("Failed to write updated posts to database");
        send_html(request, tprint("<pre>Error updating post metadata</pre>"), status_code=500);
        return;
    }

    if should_regenerate_homepage {
        regenerate_homepage(posts);
    }

    log("Successfully updated metadata for post %", id);
    send_html(request, tprint("<pre>Successfuly updated post metadata</pre>"), status_code=200);
}

regenerate_homepage :: (posts: *[..] Post) -> bool {
    log("Regenerating homepage");

    builder: String_Builder;
    builder.allocator = temp;
    init_string_builder(*builder);
    defer reset(*builder);

    append(*builder, #string END
<!DOCTYPE html>
<html>
<head><link rel="stylesheet" href="css/main.css"></head>
<header class="main-header" role="banner">
    <title>The Attic</title>
  <a href="/"><img class="header-image" src="/img/logo-transparent.png"></a>
</header>
<body>
  <div class="pure-g">

END);

    if posts == null {
        posts = load_posts();
    }
    left := true;
    for < post: <<posts {
        if !post.is_public continue;

        if left {
            append(*builder, "    <div class=\"pure-u-1 pure-u-xl-4-24\"></div>\n");
            append(*builder, "    <div class=\"pure-u-1 pure-u-xl-7-24 left-column\">\n");
            append(*builder, "      <div class=\"l-box\">\n");
        } else {
            append(*builder, "    <div class=\"pure-u-1 pure-u-xl-2-24\"></div>\n");
            append(*builder, "    <div class=\"pure-u-1 pure-u-xl-7-24 left-column\">\n");
            append(*builder, "      <div class=\"r-box\">\n");
        }

        append(*builder, tprint("        <a id=\"post-thumbnail\" href=\"api/posts/%/published\">\n", post.id));
        append(*builder, tprint("          <img class=\"post-image\" src=\"api/posts/%/thumbnail-bw.png\">\n", post.id));
        append(*builder, tprint("          <img class=\"post-image\" src=\"api/posts/%/thumbnail.png\">\n", post.id));
        append(*builder, "        </a><br/>\n");
        append(*builder, "      </div>\n");
        append(*builder, "    </div>\n");

        if !left {
            append(*builder, "    <div class=\"pure-u-1 pure-u-xl-4-24\"></div>\n\n");
        }

        left = !left;
    }

    if !left { // we ended with an empty right column, fill it in
        append(*builder, #string END
    <div class="pure-u-1 pure-u-xl-7-24 left-column">
      <div class="r-box">
      </div>
    </div>
    <div class="pure-u-1 pure-u-xl-4-24"></div>

END
        );
    }

    append(*builder, #string END
  </div>
</body>
</html>
END
    );

    homepage_backup_file :: #run tprint("%.bak", HOMEPAGE_FILE);

    // copy the current homepage to the backup file
    if !copy_file(HOMEPAGE_FILE, homepage_backup_file) {
        log("Failed to backup homepage before overwriting");
        return false;
    }

    // overwrite the current draft with the user's content
    if !write_entire_file(HOMEPAGE_FILE, *builder) {
        log("Failed to update homepage");
        // restore backup DB
        if !copy_file(homepage_backup_file, HOMEPAGE_FILE) {
            log("Failed to restore backup homepage after write failure");
        }
        return false;
    }

    log("Successfully regenerated homepage");
    return true;
}

HOMEPAGE_FILE :: "/home/grish/scratch/attic-html/index.html";

// overwrites the entire database file
write_posts_to_db :: (posts: *[..] Post) -> bool {
    #import "csv";

    builder: String_Builder;
    builder.allocator = temp;
    init_string_builder(*builder);
    defer reset(*builder);

    append(*builder, "id,author,date,title,is_public\n");

    for post: <<posts {
        append(*builder,
            join(
                tprint("%", post.id),
                csv_escape(post.author),
                post.date,
                csv_escape(post.title),
                tprint("%", post.is_public),
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

            path := tprint("/home/grish/scratch/attic/tmp/covers/%", id);
            if !make_directory_if_it_does_not_exist(path, recursive=false) {
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
                        job.title              = post.title;
                        job.author             = post.author;
                        job.state              = "READY";
                        job.error_reason       = "";
                        job.use_existing_cover = false;

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
                        false,
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

get_thumbnail_creation_status :: (request: *Request) {
    job_status: struct {
        state        : string;
        error_reason : string;
    }

    log("Have request to for thumbnail status");

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

    jobs := load_thumbnail_queue();
    found := false;
    for * job: <<jobs {
        if job.id == id {
            job_status.state        = job.state;
            job_status.error_reason = job.error_reason;
            found = true;
            break;
        }
    }
    if !found {
        send_html(request, tprint("<pre>Thumbnail job not found for this post</pre>"), status_code=404);
        return;
    }

    result := json_write_string(job_status);
    send_json(request, result);
}

Thumbnail_Job :: struct {
    id:                 int;
    title:              string;
    author:             string;
    state:              string;
    error_reason:       string;
    use_existing_cover: bool;
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

    append(*builder, "id,title,author,state,error_reason,use_existing_cover\n");

    for job: <<jobs {
        append(*builder,
            join(
                tprint("%", job.id),
                csv_escape(job.title),
                csv_escape(job.author),
                job.state,
                csv_escape(job.error_reason),
                ifx job.use_existing_cover then "true" else "false",
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

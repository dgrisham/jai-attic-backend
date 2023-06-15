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

    get("/api/authors", (request: *Request) {
        get_authors(request);
    });

    get("/api/posts/:author/:date/:filename", (request: *Request) {
        get_post(request);
    });

    // post("/api/posts/:author/:date/:filename", (request: *Request) {
    //     update_post(request);
    // });

    while 1 sleep_milliseconds(60_000); // the program just exits instantly without this
}

Authors :: Table(string, *[..]Post);

Author :: struct {
    name: string;
    posts: [..]Post;
};

Post :: struct {
    title: string;
    author: string;
    date: string;
    filename: string;
};

// POSTS_DIRECTORY :: "/usr/local/www/legacy/posts";
POSTS_DIRECTORY :: "/home/grish/scratch/attic-html/posts";
HTML_DIRECTORY :: "/home/grish/scratch/attic-html";

using #import "Hash_Table";
operator []= :: (t: *Table(string, string), index: string, value: string) {;
  table_add(t, index, value);
}

Update_Post :: struct {
    title: string;
    body: string;
}

get_post :: (request: *Request) {
    postBody: struct {
        data: string;
    }

    author, author_found := table_find(*request.params, "author");
    if !author_found {
        send_html(request, tprint("<pre>Missing author parameter</pre>"), status_code=400);
        return;
    }
    log("author: %", author);

    date, date_found := table_find(*request.params, "date");
    if !date_found {
        send_html(request, tprint("<pre>Missing date parameter</pre>"), status_code=400);
        return;
    }
    log("date: %", date);

    filename, filename_found := table_find(*request.params, "filename");
    if !filename_found {
        send_html(request, tprint("<pre>Missing filename parameter</pre>"), status_code=400);
        return;
    }
    log("filename: %", filename);

    path := replace(join(POSTS_DIRECTORY, author, date, filename, separator="/"), "%20", " ");
    defer free(path);

    log("path: %", path);
    body, success := get_post_body(path);
    if !success {
        send_html(request, tprint("<pre>Post not found</pre>"), status_code=404);
        return;
    }

    postBody.data = body;
    result := json_write_string(postBody);
    send_json(request, result);
    // table_reset(*request.params); // TODO: seems like things break without this, should be in the lib though
    reset_temporary_storage();
}

update_post :: (request: *Request) {

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

get_authors :: (request: *Request) {
    authors_table := get_authors_and_posts();
    authors: [..]Author;
    for v, k: authors_table {
        author: Author;
        author.name = k;
        author.posts = <<v;
        array_add(*authors, author);
    }
    result := json_write_string(authors);

    send_json(request, result);
    reset_temporary_storage();
}

get_authors_and_posts :: () -> Authors {

    authors: Authors;

    post_paths := get_post_paths();
    for post_path: post_paths {
        words := post_path.words;
        author_name := words[words.count-3];

        post: Post;
        post.author = author_name;
        post.date = words[words.count-2];
        post.filename = join(..array_view(words, 4), separator="/");

        title, success := parse_post_title(join(HTML_DIRECTORY, "/", post.filename));
        if success {
            post.title = title;
        }

        author_posts, author_found := table_find(*authors, author_name);
        if !author_found {
            author_posts = New([..]Post);
            table_add(*authors, author_name, author_posts);
        }
        array_add(author_posts, post);
    }

    return authors;
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

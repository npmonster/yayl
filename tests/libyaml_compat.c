/* Read the entire emitted stream and assert the edited scalar's bytes.
 * Parse acceptance and scalar values both come from the independent reader. */
#include <yaml.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    size_t checked = 0;
    for (int arg = 1; arg < argc; arg++) {
        FILE *file = fopen(argv[arg], "rb");
        if (!file) return 2;
        yaml_parser_t parser;
        if (!yaml_parser_initialize(&parser)) { fclose(file); return 2; }
        yaml_parser_set_input_file(&parser, file);
        const char *name = strrchr(argv[arg], '/');
        name = name ? name + 1 : argv[arg];
        int expected_documents = strncmp(name, "stream-", 7) == 0 ? 2 : 1;
        int done = 0, documents = 0, found_value = 0, failed = 0;
        while (!done) {
            yaml_event_t event;
            if (!yaml_parser_parse(&parser, &event)) {
                fprintf(stderr, "%s: libyaml %s: %s at %zu:%zu\n",
                        argv[arg], yaml_get_version_string(), parser.problem,
                        parser.problem_mark.line + 1, parser.problem_mark.column + 1);
                failed = 1;
                break;
            }
            if (event.type == YAML_DOCUMENT_START_EVENT) documents++;
            if (event.type == YAML_SCALAR_EVENT && event.data.scalar.length == 4 &&
                memcmp(event.data.scalar.value, "x\ny\n", 4) == 0) found_value++;
            done = event.type == YAML_STREAM_END_EVENT;
            yaml_event_delete(&event);
        }
        yaml_parser_delete(&parser);
        fclose(file);
        if (failed || documents != expected_documents || found_value != 1) {
            fprintf(stderr, "%s: expected %d documents and one exact edited value\n", argv[arg], expected_documents);
            return 1;
        }
        checked++;
    }
    printf("libyaml %s: %zu edited streams parsed with exact scalar values\n",
           yaml_get_version_string(), checked);
    return 0;
}

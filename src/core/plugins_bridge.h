#ifndef PZ_PLUGINS_BRIDGE_H
#define PZ_PLUGINS_BRIDGE_H
#include <stddef.h>
typedef struct pz_js pz_js;
pz_js *pz_js_create(void);
void pz_js_destroy(pz_js *p);
int pz_js_eval(pz_js *p, const char *source, size_t len, const char *filename);
int pz_js_load(pz_js *p, const char *source, size_t len, const char *filename);
char *pz_js_call(pz_js *p, const char *request, size_t len);
const char *pz_js_error(pz_js *p);
void pz_js_free_string(char *s);
#endif

#define _POSIX_C_SOURCE 200809L
#include "plugins_bridge.h"
#include "quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
struct pz_js { JSRuntime *rt; JSContext *ctx; JSValue dispatch; long long deadline; char error[2048]; };
static long long milliseconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000; }
static int interrupt(JSContext *ctx, void *opaque) { (void)ctx; return milliseconds() >= ((pz_js *)opaque)->deadline; }
static void failure(pz_js *p) {
    JSValue e = JS_GetException(p->ctx);
    const char *s = JS_ToCString(p->ctx, e);
    snprintf(p->error, sizeof(p->error), "%s", s ? s : "JavaScript exception (out of memory)");
    if (s) JS_FreeCString(p->ctx, s);
    JS_FreeValue(p->ctx, e);
}
/* Resolve microtasks only, under the callback's existing deadline. */
static JSValue settle(pz_js *p, JSValue value) {
    while (JS_IsPromise(value)) {
        JSPromiseStateEnum state = JS_PromiseState(p->ctx, value);
        if (state == JS_PROMISE_PENDING) {
            JSContext *job_ctx = NULL;
            if (milliseconds() >= p->deadline) {
                JS_FreeValue(p->ctx, value);
                return JS_ThrowInternalError(p->ctx, "Plugin microtask deadline exceeded");
            }
            int ran = JS_ExecutePendingJob(p->rt, &job_ctx);
            if (ran > 0) continue;
            JS_FreeValue(p->ctx, value);
            if (ran < 0 && job_ctx) return JS_Throw(p->ctx, JS_GetException(job_ctx));
            return JS_ThrowInternalError(p->ctx, "Plugin Promise requires unavailable asynchronous host APIs");
        }
        JSValue result = JS_PromiseResult(p->ctx, value);
        JS_FreeValue(p->ctx, value);
        if (state == JS_PROMISE_REJECTED) return JS_Throw(p->ctx, result);
        value = result;
    }
    return value;
}
pz_js *pz_js_create(void) {
    pz_js *p = calloc(1, sizeof(*p)); if (!p) return NULL;
    p->dispatch = JS_UNDEFINED;
    p->rt = JS_NewRuntime(); if (!p->rt) { free(p); return NULL; }
    JS_SetMemoryLimit(p->rt, 16 * 1024 * 1024); JS_SetMaxStackSize(p->rt, 512 * 1024);
    JS_SetCanBlock(p->rt, false); /* Atomics.wait must not bypass the interrupt deadline. */
    p->deadline = milliseconds() + 1000;
    JS_SetInterruptHandler(p->rt, interrupt, p);
    p->ctx = JS_NewContext(p->rt); if (!p->ctx) { pz_js_destroy(p); return NULL; }
    return p;
}
void pz_js_destroy(pz_js *p) { if (!p) return; if (p->ctx) { JS_FreeValue(p->ctx, p->dispatch); JS_FreeContext(p->ctx); } JS_FreeRuntime(p->rt); free(p); }
int pz_js_eval(pz_js *p, const char *source, size_t len, const char *filename) {
    JS_UpdateStackTop(p->rt);
    p->deadline = milliseconds() + 1000;
    JSValue v = JS_Eval(p->ctx, source, len, filename, JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) { failure(p); return -1; }
    if (JS_IsPromise(v)) { JS_FreeValue(p->ctx, v); snprintf(p->error, sizeof(p->error), "Async/Promise plugin scripts are not supported"); return -1; }
    /* Capture the bootstrap closure once, before any plugin may replace it. */
    if (JS_IsUndefined(p->dispatch)) {
        JSValue global = JS_GetGlobalObject(p->ctx);
        p->dispatch = JS_GetPropertyStr(p->ctx, global, "__pzDispatch");
        JS_FreeValue(p->ctx, global);
    }
    JS_FreeValue(p->ctx, v); return 0;
}
int pz_js_load(pz_js *p, const char *source, size_t len, const char *filename) {
    JS_UpdateStackTop(p->rt);
    p->deadline = milliseconds() + 1000;
    JSValue compiled = JS_Eval(p->ctx, source, len, filename,
                              JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(compiled)) { failure(p); return -1; }
    JSModuleDef *module = JS_VALUE_GET_PTR(compiled);
    /* Namespace export references exist only after module instantiation.
     * Retain the compiled module while EvalFunction consumes its own reference. */
    JSValue result = settle(p, JS_EvalFunction(p->ctx, JS_DupValue(p->ctx, compiled)));
    if (JS_IsException(result)) { JS_FreeValue(p->ctx, compiled); failure(p); return -1; }
    JS_FreeValue(p->ctx, result);
    JSValue ns = JS_GetModuleNamespace(p->ctx, module);
    JS_FreeValue(p->ctx, compiled);
    if (JS_IsException(ns)) { failure(p); return -1; }
    JSValue factory = JS_GetPropertyStr(p->ctx, ns, "default");
    JS_FreeValue(p->ctx, ns);
    if (JS_IsException(factory)) { failure(p); return -1; }
    if (!JS_IsUndefined(factory)) {
        if (!JS_IsFunction(p->ctx, factory)) {
            JS_FreeValue(p->ctx, factory);
            snprintf(p->error, sizeof(p->error), "Plugin default export must be a function");
            return -1;
        }
        JSValue global = JS_GetGlobalObject(p->ctx);
        JSValue api = JS_GetPropertyStr(p->ctx, global, "pz");
        JS_FreeValue(p->ctx, global);
        result = settle(p, JS_Call(p->ctx, factory, JS_UNDEFINED, 1, &api));
        JS_FreeValue(p->ctx, api);
        if (JS_IsException(result)) { JS_FreeValue(p->ctx, factory); failure(p); return -1; }
        JS_FreeValue(p->ctx, result);
    }
    JS_FreeValue(p->ctx, factory);
    return 0;
}
char *pz_js_call(pz_js *p, const char *request, size_t len) {
    JS_UpdateStackTop(p->rt);
    p->deadline = milliseconds() + 1000;
    JSValue arg = JS_NewStringLen(p->ctx, request, len);
    JSValue v = JS_Call(p->ctx, p->dispatch, JS_UNDEFINED, 1, &arg); JS_FreeValue(p->ctx, arg);
    v = settle(p, v);
    if (JS_IsException(v)) { failure(p); return NULL; }
    size_t n; const char *s = JS_ToCStringLen(p->ctx, &n, v); char *out = NULL;
    if (!s) failure(p);
    else if (n > 1024 * 1024) snprintf(p->error, sizeof(p->error), "Plugin output exceeds 1 MiB");
    else { out = malloc(n + 1); if (out) { memcpy(out, s, n); out[n] = 0; } else snprintf(p->error, sizeof(p->error), "Out of memory copying plugin result"); }
    if (s) JS_FreeCString(p->ctx, s); JS_FreeValue(p->ctx, v); return out;
}
const char *pz_js_error(pz_js *p) { return p->error; }
void pz_js_free_string(char *s) { free(s); }

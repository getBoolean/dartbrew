// U5 negative sample: thread-local storage needs R_ARM_TLS_DTPMOD32 and
// R_ARM_TLS_DTPOFF32, which the prototype rejects.
__thread int tls_counter;

int bump(void) { return ++tls_counter; }

;; (C) 2010 Jörg F. Wittenberger
;;
;; Calling C functions in native threads and call back from PThreads
;; to Scheme.
;;
;; Now there is also an egg implementing the same.  (Never touch a
;; running systems.  I'll not try it any time soon.)
;; http://wiki.call-cc.org/eggref/4/concurrent-native-callbacks

(declare
 ;; optional
 (disable-interrupts)			; checked
 ;; promises
 ;; (strict-types)
 (unsafe)
 (usual-integrations)
 (fixnum-arithmetic)
 (foreign-declare #<<EOF

#ifdef ___CHICKEN
typedef C_word obj;
#define FALSE_OBJ C_SCHEME_FALSE
#else
#include <rscheme/obj.h>
#endif
#include <stdio.h>
#include <stdlib.h>

#ifndef NO_THREAD_LOOP

#define THREAD_POOL_SIZE 5

#include <stdlib.h>
#include <pthread.h>
#include <errno.h>

typedef int (*C_pthread_request_function_t)(void *);

typedef struct _C_pthread_pool_entry {
  C_pthread_request_function_t function;
  void *data;
  void *callback;
  pthread_t thread;
}              C_pthread_pool_entry_t;

struct C_pthread_pool {
  pthread_mutex_t mutex;
  pthread_cond_t has_job;
  pthread_cond_t has_space;
  unsigned short int total, next, free;
  C_pthread_pool_entry_t *r;
};

static void *
worker_thread_loop(void *arg);

static void
C_pthread_pool_entry_init(struct C_pthread_pool * pool, C_pthread_pool_entry_t * r);

static int
C_pthread_pool_init(struct C_pthread_pool * pool)
{
  int i;

  pool->next = 0;
  pool->total = pool->free = 50;

  pthread_mutex_init(&pool->mutex, NULL);
  pthread_cond_init(&pool->has_job, NULL);
  pthread_cond_init(&pool->has_space, NULL);

  pool->r = malloc(sizeof(C_pthread_pool_entry_t) * pool->total);
  for (i = 0; i < pool->total; ++i) {
    pool->r[i].function = NULL;
    pool->r[i].data = NULL;
    pool->r[i].callback = NULL;
  }

  for (i = 0; i < THREAD_POOL_SIZE; ++i) {
    int e;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr,	/* PTHREAD_CREATE_DETACHED */
				PTHREAD_CREATE_JOINABLE);
    e = pthread_create(&(pool->r[i].thread), &attr, worker_thread_loop, pool);
    pthread_attr_destroy(&attr);
  }

  return 0;
}

static int
C_pthread_pool_send(struct C_pthread_pool * pool,
		  C_pthread_request_function_t function,
		  void *data,
		  void *callback)
{
  C_pthread_pool_entry_t *result = NULL;

  pthread_mutex_lock(&pool->mutex);

  do {

    if (pool->free) {
      result = &pool->r[pool->next];
      pool->next = (pool->next + 1) % pool->total;
      --pool->free;
    } else {
      pthread_mutex_unlock(&pool->mutex);
      return 1;

      fprintf(stderr, "DANGER: chicken waiting on thread pool space\n");
      pthread_cond_wait(&pool->has_space, &pool->mutex);

    }
  } while( result == NULL );

  result->function = function;
  result->data = data;
  result->callback = callback;

  pthread_mutex_unlock(&pool->mutex);
  pthread_cond_signal(&pool->has_job);

  return 0;
}

/* C_pthread_pool_put returns an entry into the queue (LI) and returns
 * the result to rscheme.  The latter is questionable, but we avoid to
 * take yet another lock around the interpreter callback.
 */

static void
C_pthread_pool_receive(struct C_pthread_pool * pool,
		     C_pthread_request_function_t *function,
		     void **data,
		     void **callback)
{
  C_pthread_pool_entry_t *result = NULL;

  pthread_mutex_lock(&pool->mutex);

  do {

    if (pool->free != pool->total) {
      unsigned short int target = (pool->next + pool->free) % pool->total;
      result = &pool->r[target];
      ++pool->free;
      *function = result->function;
      *data = result->data;
      *callback = result->callback;
    } else {
      pthread_cond_wait(&pool->has_job, &pool->mutex);
    }

  } while( result == NULL );

  pthread_mutex_unlock(&pool->mutex);
  pthread_cond_signal(&pool->has_space);
}

static struct C_pthread_pool *request_pool = NULL;

int
start_asynchronous_request(C_pthread_request_function_t function,
			   void *data, void *callback)
{
  if( request_pool == NULL ) {
    fprintf(stderr, "thread pool not initialised\n");
    exit(1);
  }
  return C_pthread_pool_send(request_pool, function, data, callback);
}

static pthread_mutex_t callback_mutex;
static pthread_cond_t callback_free_cond;
#ifdef ___CHICKEN
static int the_interrupt_pipe[2] = {0, 0};
static void *the_callback = NULL;
static void *the_callback_result = NULL;
static C_word the_result = C_SCHEME_FALSE;
static void *integer_result = NULL;

void C_interrupt_call(void *callback, void *result, C_word value) {
  static char buf[1] = { (char) 254 };
  if( write(the_interrupt_pipe[1], buf, 1) < 0)
    fprintf(stderr, "ERROR: sending interrupt to chicken failed\n");
  pthread_mutex_lock(&callback_mutex);
  while( the_callback != NULL ) {
#ifdef TRACE
fprintf(stderr, "wait for callback\n");
#endif
        pthread_cond_wait(&callback_free_cond, &callback_mutex);
  }

  the_result = value;
  the_callback_result = result;
  the_callback = callback;
  /* CHICKEN_interrupt(1); */
#ifdef TRACE
fprintf(stderr, "sig chick\n");
#endif
  pthread_mutex_unlock(&callback_mutex);
  pthread_cond_broadcast(&callback_free_cond);
}

static int C_chicken_interrupt_received()
{
  the_callback = NULL;
#ifdef TRACE
fprintf(stderr, "chick sign\n");
#endif
  pthread_mutex_unlock(&callback_mutex);
  return pthread_cond_broadcast(&callback_free_cond);
}

static C_word C_receive_interrupt()
{
  pthread_mutex_lock(&callback_mutex);
  while( the_callback == NULL ) {
#ifdef TRACE
fprintf(stderr, "chicken wait for callback\n");
#endif
        pthread_cond_wait(&callback_free_cond, &callback_mutex);
  }
  return CHICKEN_gc_root_ref(the_callback);
}

#endif

static void *
worker_thread_loop(void *arg)
{
  struct C_pthread_pool *pool = arg;
  C_pthread_request_function_t function = NULL;
  void *data = NULL;
  void *callback = NULL;
  int result = 0;

  //  pthread_cleanup_push(worker_thread_unlock, ressources);
  while (1) {

    C_pthread_pool_receive(request_pool, &function, &data, &callback);
    result = (*function)(data);
    /* CHICKEN_interrupt(1); */
    C_interrupt_call(callback, integer_result, result);
  }
  // pthread_cleanup_pop(1);
  return NULL;
}

void
C_pthread_pre_init(void *intres)
{
  pthread_mutex_init(&callback_mutex, NULL);
  pthread_cond_init(&callback_free_cond, NULL);
  request_pool = malloc(sizeof(struct C_pthread_pool));
  C_pthread_pool_init(request_pool);
  integer_result=intres;
#ifdef ___CHICKEN
  if( pipe(the_interrupt_pipe) == -1 )
    fprintf(stderr, "Failed to open interrupt pipe\n");
#endif
  if(pthread_setschedprio(pthread_self(), sched_get_priority_max(sched_getscheduler(0)))) {
    fprintf(stderr, "Failed to raise main thread priority.\n");
  }
}

#else  /* NO_THREAD_LOOP */

typedef int (*C_pthread_request_function_t)(void *);

int
start_asynchronous_request(C_pthread_request_function_t function,
			   void *data, void *callback){}
void
C_pthread_pre_init(void *intres)
{
  fprintf(stderr, "thread pool not initialised\n");
}

#endif

/*

int
test_C_pthread_thread_sleep(void *data)
{
  int time = (int) data;
  sleep(time);
  return time;
}

*/


EOF
)
 )

(module
 pthreads
 (
  pool-send!
  external-wait				;; undocumented may be removed
  )

(import scheme)
(cond-expand
 (chicken-5
  (import (chicken base)
	  (chicken foreign)
	  (chicken type)
	  (chicken fixnum)
	  srfi-18))
 (else
  (import chicken foreign)
  (use srfi-18)))

(: pool-send! (pointer pointer pointer -> undefined))
;; procedure data callback-gc-root
(define pool-send!
  (foreign-lambda
   void "start_asynchronous_request"
   nonnull-c-pointer nonnull-c-pointer nonnull-c-pointer))

;; (import (only atomic make-semaphore set-open-fd!))

(define-syntax set-open-fd! (syntax-rules () ((_ x y) #f)))

(define make-gc-root
  (foreign-lambda*
    c-pointer ((scheme-object obj))
    "C_GC_ROOT *r=CHICKEN_new_gc_root();"
    "CHICKEN_gc_root_set(r, obj);"
    "return(r);"))

(define interrupt-callback (foreign-lambda scheme-object "C_receive_interrupt"))
(define callback-result (foreign-lambda* int ((c-pointer result)) "C_return(* (int *) result);"))
(define callback-result-root (make-gc-root callback-result))

((foreign-lambda* void ((c-pointer f)) "C_pthread_pre_init(f);")
 callback-result-root)

(define (handle-callback)
  (let ((cb (interrupt-callback)))
    (if (procedure? cb)
	(let ((converter
	       (foreign-value "CHICKEN_gc_root_ref(the_callback_result)" scheme-object)))
	  (if (procedure? converter)
	      (let ((rc (converter (foreign-value "&the_result" c-pointer))))
		(foreign-code "C_chicken_interrupt_received();")
		(thread-start! (make-thread (lambda () (cb rc)) 'handle-callback)))
	      (begin
		(foreign-code "fprintf(stderr, \"Ignored callback no converter procedure -- does this mess up things?\\n\");exit(1);")
		)))
	(foreign-code "fprintf(stderr, \"Ignored callback -- does this mess up things?\\n\");"))) )

(define external-wait
  (thread-start!
   (make-thread
    (lambda ()
      (let ((fd ((foreign-lambda* int () "C_return(the_interrupt_pipe[0]);"))))
	(set-open-fd! fd '(pipe input interrupt-pipe))
	;;(##sys#file-nonblocking! fd)
	(do ()
	    (#f)
	  (thread-wait-for-i/o! fd #:input)
	  (if (fx= ((foreign-lambda*
		     int ()
		     "static int buf[1]; int r = read(the_interrupt_pipe[0], buf, 1); return(r);"))
		   1)
	      (handle-callback)))))
    "external-wait")))

) ;; module pthreads

/*
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include <wal_writer.h>

#include <pthread.h>

#include <third_party/crc32.h>

#include <tarantool.h>
#include <say.h>
#include <fiber.h>
#include <log_io.h>

enum {
	TASK_QUEUE_SIZE_DEFAULT = 1024,
};

/** WAL writer task */
struct wal_task {
	/** task input parameters */
	struct {
		/** WAL tag */
		u16 tag;
		/** WAL cookie */
		u64 cookie;
		/** LSN */
		i64 lsn;
		/** WAL row */
		struct tbuf *row;
	} input;
	/** task output parameters */
	struct {
		/** operation result */
		bool is_success;
	} output;
	/** task pending fiber */
	struct fiber *fiber;
};

/**
 * WAL writer task buffer
 */
struct task_buf {
	/** number elements in the buffer */
	size_t size;
	/** queue allocated size (maximal size) */
	size_t capacity;
	/** task */
	struct wal_task **entries;
};

/**
 * WAL writer task queue.
 *
 * This is not "real" queue it is work like stack. Because we put element by one
 * and pop all elements at once (we can't pop elements by one).
 */
struct task_queue {
	/** input queue */
	struct task_buf *input;
	/** output queue */
	struct task_buf *output;
	/** queue lock mutex */
	pthread_mutex_t lock_mutex;
	/** empty queue condition */
	pthread_cond_t empty_cond;
	/** pending tasks */
	bool pending_tasks;
};

/** WAL writer context */
struct wal_writer {
	/** log state */
	struct recovery_state *state;
	/** current write log */
	struct log_io *curr_log;
	/** last flush */
	ev_tstamp curr_log_last_flush;
	/** log to close */
	struct log_io *close_log;
	/** worker thread */
	pthread_t worker;
	/** worker thread done flag */
	bool worker_done;
	/** task queue */
	struct task_queue *queue;
};


/*==========================================================================
 * WAL writer local function declaration
 *==========================================================================*/

/**
 * Worker thread routine
 */
static void *
worker_loop(void *worker_args);


/*--------------------------------------------------------------------------
 * task queue interface
 *--------------------------------------------------------------------------*/

/**
 * Create new task queue instance.
 *
 * @returns new WAL writer queue instance or NULL if error occurred.
 */
static struct task_queue *
task_queue_init();

/**
 * Create new task queue instance.
 *
 * @returns new WAL writer queue instance or NULL if error occurred.
 */
static void
task_queue_destroy(struct task_queue *queue);

/**
 * Put task to queue.
 *
 * @param writer is WAL writer instance.
 * @param task is WAL write row task.
 *
 * @returns true or false if error occurred.
 */
static bool
task_queue_put_task(struct task_queue *queue, struct wal_task *task);

/**
 * Get tasks form queue.
 *
 * @returns pointer on WAL task buffer or NULL if error occurred.
 */
static struct task_buf *
task_queue_get_tasks(struct task_queue *queue);

/**
 * Lock task queue.
 *
 * @param queue is task queue.
 */
static inline void
task_queue_lock(struct task_queue *queue);

/**
 * Lock task queue.
 *
 * @param queue is task queue.
 */
static inline void
task_queue_unlock(struct task_queue *queue);


/*==========================================================================
 * WAL writer interface implementation
 *==========================================================================*/

struct wal_writer *
wal_writer_init(struct recovery_state *state, size_t queue_size)
{
	struct wal_writer *writer = malloc(sizeof(struct wal_writer));

	/* set state */
	writer->state = state;
	/* initialize current log */
	writer->curr_log = NULL;
	/* initialize close */
	writer->close_log = NULL;

	/* create task queue */
	writer->queue = task_queue_init(queue_size);

	/* run worker thread */
	writer->worker_done = false;
	int result = pthread_create(&writer->worker, NULL, worker_loop, writer);
	if (result != 0)
		panic("wal writer: thread create fail: %s", strerror(result));

	return writer;
}

void
wal_writer_destroy(struct wal_writer *writer)
{
	/* stop worker */
	writer->worker_done = true;
	int result = pthread_join(writer->worker, NULL);
	if (result != 0)
		say_error("wal writer: thread join fail: %s", strerror(result));

	/* close logs */
	if (writer->curr_log)
		log_io_close(&writer->curr_log);
	if (writer->close_log)
		log_io_close(&writer->close_log);

	/* destroy queue */
	task_queue_destroy(writer->queue);
	free(writer);
}

bool
wal_writer_write_row(struct wal_writer *writer, u16 tag, u64 cookie, i64 lsn, struct tbuf *row)
{
	struct wal_task *task = palloc(fiber->gc_pool, sizeof(struct wal_task));
	/* prepare task */
	task->input.tag = tag;
	task->input.cookie = cookie;
	task->input.lsn = lsn;
	task->input.row = row;
	task->fiber = fiber;

	/* put task to writer queue */
	if (!task_queue_put_task(writer->queue, task))
		return false;

	/* wait result */
	yield();
	return task->output.is_success;
}


/*--------------------------------------------------------------------------
 * WAL writer local function implementation
 *--------------------------------------------------------------------------*/

static void *
worker_loop(void *worker_args)
{
	struct wal_writer *writer = (struct wal_writer *) worker_args;

	while (!writer->worker_done) {
		/* get new pack of tasks */
		struct task_buf *task_buf = task_queue_get_tasks(writer->queue);
		if (task_buf->size == 0)
			continue;

		for (size_t i = 0; i < task_buf->size; ++i) {
			struct wal_task *task = task_buf->entries[i];
			task->output.is_success = false;

			if (writer->curr_log == NULL) {
				int unused;
				/* Open WAL with '.inprogress' suffix. */
				writer->curr_log = log_io_open_for_write(writer->state,
									 writer->state->wal_class,
									 task->input.lsn,
									 -1,
									 &unused);
				if (writer->curr_log == NULL)
					goto task_done;
				writer->curr_log_last_flush = 0;
			} else if (writer->curr_log->rows == 1) {
				/* rename WAL after first successful write to name
				 * without inprogress suffix*/
				if (log_io_inprogress_rename(writer->curr_log->filename) != 0)
					goto task_done;
			}

			if (writer->close_log != NULL)
				log_io_close(&writer->close_log);

			/* fill row header */
			struct row_v11 header;
			header.lsn = task->input.lsn;
			header.tm = ev_now();
			header.len = sizeof(u16) + sizeof(u64) + task->input.row->len;
			/* calculate data checksum */
			header.data_crc32c = 0;
			header.data_crc32c = crc32c(header.data_crc32c, (u8 *)&task->input.tag, sizeof(u16));
			header.data_crc32c = crc32c(header.data_crc32c, (u8 *)&task->input.cookie, sizeof(u64));
			header.data_crc32c = crc32c(header.data_crc32c, task->input.row->data, task->input.row->len);
			/* calculate header checksum */
			header.header_crc32c = crc32c(0, (u8 *)&header + sizeof(header.header_crc32c),
						      sizeof(header) - sizeof(header.header_crc32c));

			if (fwrite(&writer->curr_log->class->marker, writer->curr_log->class->marker_size, 1, writer->curr_log->f) != 1) {
				say_syserror("write marker to wal fail");
				goto task_done;
			}

			if (fwrite(&header, sizeof(header), 1, writer->curr_log->f) != 1) {
				say_syserror("write row header to wal fail");
				goto task_done;
			}

			if (fwrite(&task->input.tag, sizeof(u16), 1, writer->curr_log->f) != 1) {
				say_syserror("write row tag to wal fail");
				goto task_done;
			}

			if (fwrite(&task->input.cookie, sizeof(u64), 1, writer->curr_log->f) != 1) {
				say_syserror("write row cookie to wal fail");
				goto task_done;
			}

			if (fwrite(task->input.row->data, task->input.row->len, 1, writer->curr_log->f) != 1) {
				say_syserror("write row data to wal fail");
				goto task_done;
			}

			writer->curr_log->rows += 1;
			if (writer->curr_log->class->rows_per_file <= writer->curr_log->rows ||
			    (task->input.lsn + 1) % writer->curr_log->class->rows_per_file == 0) {
				writer->close_log = writer->curr_log;
				writer->curr_log = NULL;
			}

			task->output.is_success = true;
		task_done:
			fiber_wakeup(task->fiber);
		}

		if (writer->curr_log != NULL) {
			/* fflush log */
			fflush(writer->curr_log->f);
			/* check fsync time */
			if (writer->curr_log->class->fsync_delay > 0 &&
			    ev_now() - writer->curr_log_last_flush >= writer->curr_log->class->fsync_delay) {
				/* time to fsync */
				log_io_flush(writer->curr_log);
				writer->curr_log_last_flush = ev_now();
			}
		}
	}

	say_crit("wal writer's worker done");
	return NULL;
}


/*--------------------------------------------------------------------------
 * task queue interface
 *--------------------------------------------------------------------------*/

static struct task_queue *
task_queue_init(size_t queue_size)
{
	struct task_queue *queue = malloc(sizeof(struct task_queue));

	/* initialize queue lock mutex */
	int result = pthread_mutex_init(&queue->lock_mutex, NULL);
	if (result != 0)
		panic("wal writer: can't init mutex: %s", strerror(result));

	result = pthread_cond_init(&queue->empty_cond, NULL);
	if (result != 0)
		panic("wal writer: can't init cond: %s", strerror(result));

	queue->pending_tasks = false;

	/* initialize first buffer */
	queue->input = malloc(sizeof(struct task_buf));
	queue->input->size = 0;
	queue->input->capacity = queue_size;
	queue->input->entries = malloc(sizeof(struct wal_task *) * queue_size);

	/* initialize second buffer */
	queue->output = malloc(sizeof(struct task_buf));
	queue->output->size = 0;
	queue->output->capacity = queue_size;
	queue->output->entries = malloc(sizeof(struct wal_task *) * queue_size);

	return queue;
}

static void
task_queue_destroy(struct task_queue *queue)
{
	/* destroy first buffer */
	free(queue->input->entries);
	free(queue->input);

	/* destroy second buffer */
	free(queue->output->entries);
	free(queue->output);

	/* destroy lock queue mutex */
	pthread_mutex_destroy(&queue->lock_mutex);

	/* destroy empty queue condition */
	pthread_cond_destroy(&queue->empty_cond);
}

static bool
task_queue_put_task(struct task_queue *queue, struct wal_task *task)
{
	task_queue_lock(queue);

	bool is_success = false;
	if (queue->input->size >= queue->input->capacity) {
		/* no more space in the input buffer */
		say_error("wal writer: task queue overflow");
		goto put_task_done;
	}

	/* put task */
	queue->input->entries[queue->input->size] = task;
	queue->input->size += 1;

	if (queue->pending_tasks) {
		/* writer's worker pending task, signal to him */
		pthread_cond_signal(&queue->empty_cond);
	}

	is_success = true;
put_task_done:
	task_queue_unlock(queue);
	return is_success;
}

static struct task_buf *
task_queue_get_tasks(struct task_queue *queue)
{
	task_queue_lock(queue);

	if (queue->input->size == 0) {
		struct timespec timeout;

		clock_gettime(CLOCK_REALTIME, &timeout);
		timeout.tv_nsec += 100000000; /* 0.1 sec timeout */

		queue->pending_tasks = true;
		pthread_cond_timedwait(&queue->empty_cond, &queue->lock_mutex, &timeout);
		queue->pending_tasks = false;
	}

	/* swap task buffers */
	struct task_buf *tasks = queue->input;
	queue->input = queue->output;
	queue->output = tasks;

	/* clean-up input buffer */
	queue->input->size = 0;

	task_queue_unlock(queue);
	return tasks;
}

static inline void
task_queue_lock(struct task_queue *queue)
{
	int result = pthread_mutex_lock(&queue->lock_mutex);
	if (result != 0)
		panic("wal writer: can't lock task queue: %s", strerror(result));
}

static inline void
task_queue_unlock(struct task_queue *queue)
{
	int result = pthread_mutex_unlock(&queue->lock_mutex);
	if (result != 0)
		panic("wal writer: can't unlock task queue: %s", strerror(result));
}


#ifndef TARANTOOL_WAL_WRITER_H_INCLUDED
#define TARANTOOL_WAL_WRITER_H_INCLUDED
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
#include <stdbool.h>

#include <util.h>
#include <tbuf.h>


struct recovery_state;

/** wal writer structure declaration */
struct wal_writer;


/*--------------------------------------------------------------------------
 * WAL writer interface declaration
 *--------------------------------------------------------------------------*/

/**
 * Create new WAL writer instance.
 *
 * @params state is log state.
 * @params queue_size is task queue size.
 *
 * @returns new WAL writer instance or NULL if error occurred.
 */
struct wal_writer *
wal_writer_init(struct recovery_state *state, size_t queue_size);

/**
 * Destroy WAL writer instance.
 *
 * @param writer is WAL writer instance.
 */
void
wal_writer_destroy(struct wal_writer *writer);

/**
 * Write row to WAL.
 *
 * @param writer is WAL writer instance.
 * @param tag is WAL tag.
 * @param cookie is WAL cookie.
 * @param lsn is LSN.
 * @param row is WAL row.
 *
 * @returns true on success. On error, false is returned.
 */
bool
wal_writer_write_row(struct wal_writer *writer, u16 tag, u64 cookie, i64 lsn, struct tbuf *row);

#endif /* TARANTOOL_WAL_WRITER_H_INCLUDED */


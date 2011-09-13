#ifndef TARANTOOL_BOX_H_INCLUDED
#define TARANTOOL_BOX_H_INCLUDED
/*
 * Copyright (C) 2010 Mail.RU
 * Copyright (C) 2010 Yuriy Vostrikov
 *
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

#include <mod/box/index.h>
#include "exception.h"
#include "iproto.h"
#include <tbuf.h>
#include <fiber.h>

struct tarantool_cfg;
struct box_tuple;
struct index;

enum
{
	BOX_INDEX_MAX = 10,
	BOX_NAMESPACE_MAX = 256,
	/** update fields operations counter maximal value */
	BOX_UPDATE_FIELDS_OP_CNT_MAX = 128,
};

struct space {
	int n;
	bool enabled;
	int cardinality;
	struct index index[BOX_INDEX_MAX];
};

extern struct space *space;

struct box_out {
	void (*add_u32)(u32 *u32);
	void (*dup_u32)(u32 u32);
	void (*add_tuple)(struct box_tuple *tuple);
};

extern struct box_out box_out_quiet;

struct box_txn {
	u16 op;
	u32 flags;

	struct lua_State *L;
	struct box_out *out;
	struct space *space;
	struct index *index;
	int n;

	struct tbuf *ref_tuples;
	struct box_tuple *old_tuple;
	struct box_tuple *tuple;
	struct box_tuple *lock_tuple;

	struct tbuf req;
};


#define BOX_RETURN_TUPLE		0x01
#define BOX_ADD				0x02
#define BOX_REPLACE			0x04
#define BOX_NOT_STORE			0x10
#define BOX_GC_TXN			0x20
#define BOX_ALLOWED_REQUEST_FLAGS	(BOX_RETURN_TUPLE | \
					 BOX_ADD | \
					 BOX_REPLACE | \
					 BOX_NOT_STORE)

/*
    deprecated commands:
        _(INSERT, 1)
        _(DELETE, 2)
        _(SET_FIELD, 3)
        _(ARITH, 5)
        _(SET_FIELD, 6)
        _(ARITH, 7)
        _(SELECT, 4)
        _(DELETE, 8)
        _(UPDATE_FIELDS, 9)
        _(INSERT,10)
        _(JUBOX_ALIVE, 11)
        _(SELECT_LIMIT, 12)
        _(SELECT_OLD, 14)
        _(SELECT_LIMIT, 15)
        _(UPDATE_FIELDS_OLD, 16)

    DO NOT use these ids!
 */
#define MESSAGES(_)				\
        _(REPLACE, 13)				\
	_(SELECT, 17)				\
	_(UPDATE, 19)				\
	_(DELETE_1_3, 20)			\
	_(DELETE, 21)				\
	_(CALL, 22)

ENUM(messages, MESSAGES);

/*
 * update fields operations codes
 */
#define UPDATE_FIELDS_OPCODES(_)		\
	_(UPDATE_SET_FIELD, 0)			\
	_(UPDATE_ADD_INT, 1)			\
	_(UPDATE_BIT_AND_INT, 2)		\
	_(UPDATE_BIT_XOR_INT, 3)		\
	_(UPDATE_BIT_OR_INT, 4)			\
	_(UPDATE_SPLICE_STR, 5)			\
	_(UPDATE_DELETE_FIELD, 6)		\

ENUM(update_fields_opcodes, UPDATE_FIELDS_OPCODES);


extern iproto_callback rw_callback;

/* These are used to implement memcached 'GET' */
static inline struct box_txn *in_txn() { return fiber->mod_data.txn; }
struct box_txn *txn_begin();
void txn_commit(struct box_txn *txn);
void txn_rollback(struct box_txn *txn);
void tuple_txn_ref(struct box_txn *txn, struct box_tuple *tuple);

#endif /* TARANTOOL_BOX_H_INCLUDED */

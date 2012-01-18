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
#include <mod/box/box.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <arpa/inet.h>

#include <cfg/warning.h>
#include <errcode.h>
#include <fiber.h>
#include <log_io.h>
#include <pickle.h>
#include <salloc.h>
#include <say.h>
#include <stat.h>
#include <tarantool.h>
#include <tbuf.h>
#include <util.h>

#include <cfg/tarantool_box_cfg.h>
#include <mod/box/tuple.h>
#include "memcached.h"
#include "box_lua.h"

struct op_set_arg {
	/** set length */
	u32 length;
	/** set value */
	void *value;
};

/** arith operands */
struct op_arith_arg {
	/** arith value size */
	u32 size;
	i32 i32_val;
};

/** splice operands */
struct op_splice_arg {
	/** splice position */
	i32 offset;
	/** cut length */
	i32 length;
	/** paste list length */
	i32 list_length;
	/** paste list */
	void *list;
};

union op_arg {
	struct op_set_arg set;
	struct op_arith_arg arith;
	struct op_splice_arg splice;
};

/** A single UPDATE operation. */
struct update_op {
	/** fields number */
	u32 field_no;
	/** operation code */
	u8 opcode;
	/* skip this operation */
	bool skip;
	/** operands */
	union op_arg arg;
	/** field length after apply operation */
	u32 new_field_len;
};

/** UPDATE command context. */
struct update_cmd {
	/** search key */
	void *key;
	/** operations */
	struct update_op *op;
	/** number of operation in the command */
	u32 op_cnt;
	/** search key cardinality */
	u32 key_cardinality;
	/** new tuple length after apply all operations */
	u32 new_tuple_len;
};

static void box_process_ro(u32 op, struct tbuf *request_data);
static void box_process_rw(u32 op, struct tbuf *request_data);

const char *mod_name = "Box";

iproto_callback rw_callback = box_process_ro;
static char status[64] = "unknown";

static int stat_base;
STRS(messages, MESSAGES);

/*
  For tuples of size below this threshold, when sending a tuple
  to the client, make a deep copy of the tuple for the duration
  of sending rather than increment a reference counter.
  This is necessary to avoid excessive page splits when taking
  a snapshot: many small tuples can be accessed by clients
  immediately after the snapshot process has forked off,
  thus incrementing tuple ref count, and causing the OS to
  create a copy of the memory page for the forked
  child.
*/

const int BOX_REF_THRESHOLD = 8196;

struct space *space = NULL;

struct box_snap_row {
	u32 space;
	u32 tuple_size;
	u32 data_size;
	u8 data[];
} __attribute__((packed));


static inline struct box_snap_row *
box_snap_row(const struct tbuf *t)
{
	return (struct box_snap_row *)t->data;
}

static void
lock_tuple(struct box_txn *txn, struct box_tuple *tuple)
{
	if (tuple->flags & WAL_WAIT)
		tnt_raise(ClientError, :ER_TUPLE_IS_RO);

	say_debug("lock_tuple(%p)", tuple);
	txn->lock_tuple = tuple;
	tuple->flags |= WAL_WAIT;
}

static void
unlock_tuples(struct box_txn *txn)
{
	if (txn->lock_tuple) {
		txn->lock_tuple->flags &= ~WAL_WAIT;
		txn->lock_tuple = NULL;
	}
}

void
tuple_txn_ref(struct box_txn *txn, struct box_tuple *tuple)
{
	say_debug("tuple_txn_ref(%p)", tuple);
	tbuf_append(txn->ref_tuples, &tuple, sizeof(struct box_tuple *));
	tuple_ref(tuple, +1);
}

void
validate_indexes(struct box_txn *txn)
{
	if (space[txn->n].index[1] == nil)
		return;

	/* There is more than one index. */
	foreach_index(txn->n, index) {
		/* XXX: skip the first index here! */
		for (u32 f = 0; f < index->key_def.part_count; ++f) {
			if (index->key_def.parts[f].fieldno >= txn->tuple->cardinality)
				tnt_raise(IllegalParams, :"tuple must have all indexed fields");

			if (index->key_def.parts[f].type == STRING)
				continue;

			void *field = tuple_field(txn->tuple, index->key_def.parts[f].fieldno);
			u32 len = load_varint32(&field);

			if (index->key_def.parts[f].type == NUM && len != sizeof(u32))
				tnt_raise(IllegalParams, :"field must be NUM");

			if (index->key_def.parts[f].type == NUM64 && len != sizeof(u64))
				tnt_raise(IllegalParams, :"field must be NUM64");
		}
		if (index->type == TREE && index->key_def.is_unique == false)
			/* Don't check non unique indexes */
			continue;

		struct box_tuple *tuple = [index findByTuple: txn->tuple];

		if (tuple != NULL && tuple != txn->old_tuple)
			tnt_raise(ClientError, :ER_INDEX_VIOLATION);
	}
}

static void __attribute__((noinline))
prepare_replace(struct box_txn *txn, size_t cardinality, struct tbuf *data)
{
	assert(data != NULL);
	if (cardinality == 0)
		tnt_raise(IllegalParams, :"tuple cardinality is 0");

	if (data->size == 0 || data->size != valid_tuple(data, cardinality))
		tnt_raise(IllegalParams, :"incorrect tuple length");

	txn->tuple = tuple_alloc(data->size);
	tuple_txn_ref(txn, txn->tuple);
	txn->tuple->cardinality = cardinality;
	memcpy(txn->tuple->data, data->data, data->size);

	txn->old_tuple = [txn->index findByTuple: txn->tuple];

	if (txn->old_tuple != NULL)
		tuple_txn_ref(txn, txn->old_tuple);

	if (txn->flags & BOX_ADD && txn->old_tuple != NULL)
		tnt_raise(ClientError, :ER_TUPLE_FOUND);

	if (txn->flags & BOX_REPLACE && txn->old_tuple == NULL)
		tnt_raise(ClientError, :ER_TUPLE_NOT_FOUND);

	validate_indexes(txn);

	if (txn->old_tuple != NULL) {
#ifndef NDEBUG
		void *ka, *kb;
		ka = tuple_field(txn->tuple, txn->index->key_def.parts[0].fieldno);
		kb = tuple_field(txn->old_tuple, txn->index->key_def.parts[0].fieldno);
		int kal, kab;
		kal = load_varint32(&ka);
		kab = load_varint32(&kb);
		assert(kal == kab && memcmp(ka, kb, kal) == 0);
#endif
		lock_tuple(txn, txn->old_tuple);
	} else {
		lock_tuple(txn, txn->tuple);
		/*
		 * Mark the tuple as ghost before attempting an
		 * index replace: if it fails, txn_rollback() will
		 * look at the flag and remove the tuple.
		 */
		txn->tuple->flags |= GHOST;
		/*
		 * If the tuple doesn't exist, insert a GHOST
		 * tuple in all indices in order to avoid a race
		 * condition when another REPLACE comes along:
		 * a concurrent REPLACE, UPDATE, or DELETE, returns
		 * an error when meets a ghost tuple.
		 *
		 * Tuple reference counter will be incremented in
		 * txn_commit().
		 */
		foreach_index(txn->n, index)
			[index replace: NULL :txn->tuple];
	}

	txn->out->dup_u32(1); /* Affected tuples */

	if (txn->flags & BOX_RETURN_TUPLE)
		txn->out->add_tuple(txn->tuple);
}

static void
commit_replace(struct box_txn *txn)
{
	if (txn->old_tuple != NULL) {
		foreach_index(txn->n, index)
			[index replace: txn->old_tuple :txn->tuple];

		tuple_ref(txn->old_tuple, -1);
	}

	if (txn->tuple != NULL) {
		txn->tuple->flags &= ~GHOST;
		tuple_ref(txn->tuple, +1);
	}
}

static void
rollback_replace(struct box_txn *txn)
{
	say_debug("rollback_replace: txn->tuple:%p", txn->tuple);

	if (txn->tuple && txn->tuple->flags & GHOST) {
		foreach_index(txn->n, index)
			[index remove: txn->tuple];
	}
}

static i32
field_to_i32(void *field)
{
	u32 field_length = load_varint32(&field);
	if (field_length == 0)
		return 0;
	if (field_length != sizeof(i32))
		tnt_raise(IllegalParams, :"field splice: wrong operand type");

	return * (i32 *)field;
}

static struct update_cmd *
parse_update_cmd(struct tbuf *data)
{
	struct update_cmd *cmd = palloc(fiber->gc_pool, sizeof(struct update_cmd));

	/* keys cardinality */
	cmd->key_cardinality = read_u32(data);
	if (cmd->key_cardinality > 1)
		tnt_raise(IllegalParams, :"key must be single valued");
	if (cmd->key_cardinality == 0)
		tnt_raise(IllegalParams, :"key is not defined");

	/* key */
	cmd->key = read_field(data);

	/* number of operations */
	cmd->op_cnt = read_u32(data);
	if (cmd->op_cnt > BOX_UPDATE_OP_CNT_MAX)
		tnt_raise(IllegalParams, :"too many operations for update");
	if (cmd->op_cnt == 0)
		tnt_raise(IllegalParams, :"no operations for update");

	/* read update operations */
	cmd->op = palloc(fiber->gc_pool, cmd->op_cnt * sizeof(struct update_op));
	struct update_op *op = cmd->op;
	for (; op < cmd->op + < cmd->op_cnt; ++op) {
		/* read operation */
		op->field_no = read_u32(data);
		op->opcode = read_u8(data);
		op->arg.set.value = read_field(data);
		op->arg.set.length = load_varint32(&op->arg.set.value);
	}
	/* check last data length, it must be fully read */
	if (data->size != 0)
		tnt_raise(IllegalParams, :"can't unpack request");

	return cmd;
}

static int
update_op_cmp(const void *op1_ptr, const void *op2_ptr)
{
	const struct update_op *op1 = op1_ptr;
	const struct update_op *op2 = op2_ptr;

	if (op1->field_no < op2->field_no)
		return -1;
	if (op1->field_no > op2->field_no)
		return 1;

	if (op1->arg.set.value < op2->arg.set.value)
		return -1;
	if (op1->arg.set.value > op2->arg.set.value)
		return 1;
	return 0;
}

static void
init_update_op_set(struct update_op *op, u32 field_len __attribute__((unused)))
{
	/* save fields length */
	op->new_field_len = op->arg.set.length;
}

static void
init_update_op_arith(struct update_op *op, u32 field_len)
{
	/* check arguments */
	if (field_len != sizeof(i32))
		tnt_raise(ClientError, :ER_TYPE_MISMATCH,
		       "field arithmetics: field type must be a 32-bit int");

	if (op->arg.set.length != sizeof(i32))
		tnt_raise(ClientError, :ER_TYPE_MISMATCH,
		       "field arithmetics: operand type must be a 32-bit int");

	/* parse arith operands */
	op->arg.arith.size = op->arg.set.length;
	op->arg.arith.i32_val = *(i32*)op->arg.set.value;
	/* save fields length */
	op->new_field_len = op->arg.arith.size;
}

static void
init_update_op_splice(struct update_op *op, u32 field_len)
{
	struct tbuf operands = {
		.capacity = op->arg.set.length,
		.size = op->arg.set.length,
		.data = op->arg.set.value,
		.pool = NULL
	};

	/* read offset */
	void *offset_field = read_field(&operands);
	op->arg.splice.offset = field_to_i32(offset_field);
	if (op->arg.splice.offset < 0) {
		if (-op->arg.splice.offset > field_len)
			tnt_raise(ClientError, :ER_SPLICE,
				  "offset is out of bound");
		op->arg.splice.offset = op->arg.splice.offset + field_len;
	} else if (op->arg.splice.offset > field_len) {
		op->arg.splice.offset = field_len;
	}

	/* read length */
	void *length_field = read_field(&operands);
	op->arg.splice.length = field_to_i32(length_field);
	if (op->arg.splice.length < 0) {
		if (-op->arg.splice.length > (field_len - op->arg.splice.offset))
			op->arg.splice.length = 0;
		else
			op->arg.splice.length = op->arg.splice.length
				+ field_len - op->arg.splice.offset;
	} else if (op->arg.splice.length > (field_len - op->arg.splice.offset)) {
		op->arg.splice.length = field_len - op->arg.splice.offset;
	}

	/* read list */
	void *list_field = read_field(&operands);
	op->arg.splice.list_length = load_varint32(&list_field);
	op->arg.splice.list = list_field;

	/* check last operands data length, it must be fully read */
	if (operands.size != 0)
		tnt_raise(IllegalParams, :"field splice format error");

	/* save fields length */
	op->new_field_len = op->arg.splice.offset;
	op->new_field_len += op->arg.splice.list_length;
	op->new_field_len += field_len - (op->arg.splice.offset + op->arg.splice.length);
}

static void
init_update_operations(struct box_txn *txn, struct update_cmd *cmd)
{
	/* sort operations by fields  */
	qsort(cmd->op, cmd->op_cnt, sizeof(struct update_op), update_op_cmp);

	void *old_tuple_data = (uint8_t *)txn->old_tuple->data;
	u32 op_no = 0;
	u32 field_no = 0;
	u32 new_tuple_len = 0;
	while (op_no < cmd->op_cnt || field_no < txn->old_tuple->cardinality) {
		u32 old_field_len;
		bool field_exists;

		if (field_no < txn->old_tuple->cardinality) {
			/* we have a read */
			old_field_len = load_varint32(&old_tuple_data);
			field_exists = true;
		} else {
			struct update_op *op = &cmd->op[op_no];
			/* all old tuple fields are processed, but command might be
			   contain append field operations */
			/* for new field must be at least one operation */
			if (op->field_no != field_no)
				tnt_raise(ClientError, :ER_NO_SUCH_FIELD, op->field_no);
			old_field_len = 0;
			field_exists = false;
		}
		u32 field_len = old_field_len;

		int op_begin = op_no;
		int op_useful = op_no;
		while (op_no < cmd->op_cnt) {
			struct update_op *op = &cmd->op[op_no];

			/* since the operations are ordered with respect to
			   field number operation field number must be grater
			   or equal current field number */
			if (op->field_no > field_no) {
				/* no more operation for this field */
				break;
			}

			if (!field_exists && op->opcode != UPDATE_SET_FIELD)
				tnt_raise(ClientError, :ER_NO_SUCH_FIELD, op->field_no);

			op->skip = false;
			switch (op->opcode) {
			case UPDATE_SET_FIELD:
				init_update_op_set(op, field_len);
				op_useful = op_no;
				field_exists = true;
				break;
			case UPDATE_ADD_INT:
			case UPDATE_BIT_AND_INT:
			case UPDATE_BIT_XOR_INT:
			case UPDATE_BIT_OR_INT:
				init_update_op_arith(op, field_len);
				break;
			case UPDATE_SPLICE_STR:
				init_update_op_splice(op, field_len);
				break;
			case UPDATE_DELETE_FIELD:
				op->new_field_len = 0;
				op_useful = op_no;
				field_exists = false;
				break;
			default:
				tnt_raise(ClientError, :ER_UNKNOWN_UPDATE_OP,
					  (int) op->opcode);
			}
			field_len = op->new_field_len;

			op_no += 1;
		}

		/* skip all useless operations */
		for (u32 op_useless = op_begin; op_useless < op_useful; ++op_useless)
			cmd->op[op_useless].skip = true;

		if (field_exists)
			new_tuple_len += varint32_sizeof(field_len) + field_len;

		/* go to next field */
		old_tuple_data += old_field_len;
		field_no += 1;
	}

	if (new_tuple_len > MAX_SLAB_ITEM)
		tnt_raise(ClientError, :ER_TUPLE_IS_TOO_LONG, new_tuple_len);

	cmd->new_tuple_len = new_tuple_len;
}

void
do_update_op_set(struct update_op *op, struct tbuf **field_ptr,
		 bool *inplace)
{
	struct tbuf *field = *field_ptr;

	u32 new_field_len = varint32_sizeof(op->arg.set.length) + op->arg.set.length;
	if (new_field_len > field->size) {
		/* operation can not be apply in place, create separate buffer */
		if (*inplace) {
			/* in this case new must create a new tbuf, because it was "fake" tbuf,
			   witch placed in the new tuple */
			field = tbuf_alloc(fiber->gc_pool);
			*field_ptr = field;
			*inplace = false;
		}
		tbuf_ensure(field, new_field_len);
	}

	/* copy new field */
	void *field_value = save_varint32(field->data, op->arg.set.length);
	memcpy(field_value, op->arg.set.value, op->arg.set.length);
	field->size = new_field_len;
}

void
do_update_op_arith(struct update_op *op, struct tbuf **field_ptr,
		   bool *inplace __attribute__((unused)))
{
	struct tbuf *field = *field_ptr;
	void *field_value = field->data + varint32_sizeof(field->size);
	switch (op->opcode) {
	case UPDATE_ADD_INT:
		*(i32 *)field_value += op->arg.arith.i32_val;
		break;
	case UPDATE_BIT_AND_INT:
		*(u32 *)field_value &= op->arg.arith.i32_val;
		break;
	case UPDATE_BIT_XOR_INT:
		*(u32 *)field_value ^= op->arg.arith.i32_val;
		break;
	case UPDATE_BIT_OR_INT:
		*(u32 *)field_value |= op->arg.arith.i32_val;
		break;
	}
}

void
do_update_op_splice(struct update_op *op, struct tbuf **field_ptr,
		    bool *inplace)
{
	struct tbuf *field = *field_ptr;
	/* splice do always in the separate buffer */
	*inplace = false;

	/* allocate new field */
	struct tbuf *new_field = tbuf_alloc(fiber->gc_pool);

	/* save field length */
	tbuf_ensure(new_field, varint32_sizeof(op->new_field_len));
	save_varint32(new_field->data, op->new_field_len);
	new_field->size += varint32_sizeof(op->new_field_len);

	/* save field value */
	u32 field_length = field->size - varint32_sizeof(field->size);
	void *field_value = field->data + varint32_sizeof(field->size);

	tbuf_append(new_field, field_value, op->arg.splice.offset);
	tbuf_append(new_field, op->arg.splice.list, op->arg.splice.list_length);
	tbuf_append(new_field,
		    field_value + op->arg.splice.offset + op->arg.splice.length,
		    field_length - (op->arg.splice.offset + op->arg.splice.length));

	*field = *new_field;
}

static void
do_update(struct box_txn *txn, struct update_cmd *cmd)
{
	/* old tuple */
	struct tbuf old_tuple = {
		.capacity = txn->old_tuple->bsize,
		.size = txn->old_tuple->bsize,
		.data = txn->old_tuple->data,
		.pool = NULL
	};
	/* new tuple */
	struct tbuf tuple = {
		.capacity = txn->tuple->bsize,
		.size = txn->tuple->bsize,
		.data = txn->tuple->data,
		.pool = NULL
	};

	txn->tuple->cardinality = 0;
	u32 op_no = 0;
	u32 field_no = 0;
	while (op_no < cmd->op_cnt || field_no < txn->old_tuple->cardinality) {
		struct tbuf inplace_field;
		struct tbuf *field;
		bool field_exists;
		bool inplace;

		u32 old_value_len;
		void *old_value;
		if (field_no < txn->old_tuple->cardinality) {
			/* read field from old tuple */
			void *old_field = read_field(&old_tuple);
			old_value_len = load_varint32(&old_field);
			old_value = old_field;
			field_exists = true;
		} else {
			old_value_len = 0;
			old_value = NULL;
			field_exists = false;
		}

		u32 old_field_len = varint32_sizeof(old_value_len) + old_value_len;
		if (old_field_len <= tuple.size) {
			/* field can be put to new tuple */

			/* move field to new tuple */
			/* save field size */
			void *field_value = save_varint32(tuple.data, old_value_len);
			/* save field data */
			memcpy(field_value, old_value, old_value_len);

			inplace_field.size = old_field_len;
			inplace_field.capacity = tuple.size;
			inplace_field.data = tuple.data;

			field = &inplace_field;
			inplace = true;
		} else {
			/* allocate separate buffer required */
			field = tbuf_alloc(fiber->gc_pool);
			tbuf_ensure(field, old_field_len);

			/* move field to new buffer */
			/* save field size */
			void *field_value = save_varint32(field->data, old_value_len);
			/* save field data */
			memcpy(field_value, old_value, old_value_len);
			field->size = old_field_len;
			inplace = false;
		}

		/* apply operations to field */
		while (op_no < cmd->op_cnt) {
			struct update_op *op = &cmd->op[op_no];

			/* since the operations are ordered with respect to field number
			  operation field number must be grater or equal current field number */
			if (op->field_no > field_no) {
				/* no more operation for this field */
				break;
			}

			if (op->skip)
				goto next_operaion;

			switch (op->opcode) {
			case UPDATE_SET_FIELD:
				do_update_op_set(op, &field, &inplace);
				field_exists = true;
				break;
			case UPDATE_ADD_INT:
			case UPDATE_BIT_AND_INT:
			case UPDATE_BIT_XOR_INT:
			case UPDATE_BIT_OR_INT:
				do_update_op_arith(op, &field, &inplace);
				break;
			case UPDATE_SPLICE_STR:
				do_update_op_splice(op, &field, &inplace);
				break;
			case UPDATE_DELETE_FIELD:
				field_exists = false;
				break;
			}

		next_operaion:
			op_no += 1;
		}

		if (field_exists) {
			if (!inplace) {
				assert(tuple.size >= field->size);
				memcpy(tuple.data, field->data, field->size);
			}

			tuple.data += field->size;
			tuple.size -= field->size;
			txn->tuple->cardinality += 1;
		}
		field_no += 1;
	}

	validate_indexes(txn);
}

static void __attribute__((noinline))
prepare_update(struct box_txn *txn, struct tbuf *data)
{
	u32 tuples_affected = 1;

	/* parse update command */
	struct update_cmd *cmd = parse_update_cmd(data);

	/* try to find updating tuple */
	txn->old_tuple = [txn->index find :cmd->key];
	if (txn->old_tuple == NULL) {
		/* tuple with same key not exist */
		/* this command useless, it not be logged in the WAL */
		txn->flags |= BOX_NOT_STORE;
		tuples_affected = 0;
		goto out;
	}
	/* lock tuple for changes from another commands */
	lock_tuple(txn, txn->old_tuple);

	/* prepare apply update fields */
	init_update_operations(txn, cmd);

	/* allocate new tuple */
	txn->tuple = tuple_alloc(cmd->new_tuple_len);
	tuple_txn_ref(txn, txn->tuple);

	/* apply operations to new tuple */
	do_update(txn, cmd);
out:
	txn->out->dup_u32(tuples_affected);

	if (txn->flags & BOX_RETURN_TUPLE && txn->tuple)
		txn->out->add_tuple(txn->tuple);
}

static void __attribute__((noinline))
process_select(struct box_txn *txn, u32 limit, u32 offset, struct tbuf *data)
{
	struct box_tuple *tuple;
	uint32_t *found;
	u32 count = read_u32(data);
	if (count == 0)
		tnt_raise(IllegalParams, :"tuple count must be positive");

	found = palloc(fiber->gc_pool, sizeof(*found));
	txn->out->add_u32(found);
	*found = 0;

	for (u32 i = 0; i < count; i++) {

		Index *index = txn->index;
		/* End the loop if reached the limit. */
		if (limit == *found)
			return;

		u32 key_cardinality = read_u32(data);
		void *key = NULL;

		if (key_cardinality != 0)
			key = read_field(data);

		/*
		 * For TREE indexes, we allow partially specified
		 * keys. HASH indexes are always unique and can
		 * not have multiple parts.
		 */
		if (index->type == HASH && key_cardinality != 1)
			tnt_raise(IllegalParams, :"key must be single valued");

		/* advance remaining fields of a key */
		for (int i = 1; i < key_cardinality; i++)
			read_field(data);

		struct iterator *it = index->position;
		[index initIterator: it :key :key_cardinality];

		while ((tuple = it->next_equal(it)) != NULL) {
			if (tuple->flags & GHOST)
				continue;

			if (offset > 0) {
				offset--;
				continue;
			}

			txn->out->add_tuple(tuple);

			if (limit == ++(*found))
				break;
		}
	}
	if (data->size != 0)
		tnt_raise(IllegalParams, :"can't unpack request");
}

static void __attribute__((noinline))
prepare_delete(struct box_txn *txn, void *key)
{
	u32 tuples_affected = 0;

	txn->old_tuple = [txn->index find: key];

	if (txn->old_tuple == NULL)
		/*
		 * There is no subject tuple we could write to WAL, which means,
		 * to do a write, we would have to allocate one. Too complicated,
		 * for now, just do no logging for DELETEs that do nothing.
		 */
		txn->flags |= BOX_NOT_STORE;
	else {
		tuple_txn_ref(txn, txn->old_tuple);
		lock_tuple(txn, txn->old_tuple);

		tuples_affected = 1;
	}

	txn->out->dup_u32(tuples_affected);

	if (txn->old_tuple && (txn->flags & BOX_RETURN_TUPLE))
		txn->out->add_tuple(txn->old_tuple);
}

static void
commit_delete(struct box_txn *txn)
{
	if (txn->old_tuple == NULL)
		return;

	foreach_index(txn->n, index)
		[index remove: txn->old_tuple];
	tuple_ref(txn->old_tuple, -1);
}

static bool
op_is_select(u32 op)
{
	return op == SELECT || op == CALL;
}

static void
iov_add_u32(u32 *p_u32)
{
	iov_add(p_u32, sizeof(u32));
}

static void
iov_dup_u32(u32 u32)
{
	iov_dup(&u32, sizeof(u32));
}

static void
iov_add_tuple(struct box_tuple *tuple)
{
	size_t len = tuple_len(tuple);

	if (len > BOX_REF_THRESHOLD) {
		tuple_txn_ref(in_txn(), tuple);
		iov_add(&tuple->bsize, len);
	} else {
		iov_dup(&tuple->bsize, len);
	}
}

static struct box_out box_out_iproto = {
	iov_add_u32,
	iov_dup_u32,
	iov_add_tuple
};

static void box_quiet_add_u32(u32 *p_u32 __attribute__((unused))) {}
static void box_quiet_dup_u32(u32 u32 __attribute__((unused))) {}
static void box_quiet_add_tuple(struct box_tuple *tuple __attribute__((unused))) {}

struct box_out box_out_quiet = {
	box_quiet_add_u32,
	box_quiet_dup_u32,
	box_quiet_add_tuple
};

struct box_txn *
txn_begin()
{
	struct box_txn *txn = p0alloc(fiber->gc_pool, sizeof(*txn));
	txn->ref_tuples = tbuf_alloc(fiber->gc_pool);
	assert(fiber->mod_data.txn == NULL);
	fiber->mod_data.txn = txn;
	return txn;
}

void txn_assign_n(struct box_txn *txn, struct tbuf *data)
{
	txn->n = read_u32(data);

	if (txn->n < 0 || txn->n >= BOX_SPACE_MAX)
		tnt_raise(ClientError, :ER_NO_SUCH_SPACE, txn->n);

	txn->space = &space[txn->n];

	if (!txn->space->enabled)
		tnt_raise(ClientError, :ER_SPACE_DISABLED, txn->n);

	txn->index = txn->space->index[0];
}

/** Remember op code/request in the txn. */
static void
txn_set_op(struct box_txn *txn, u16 op, struct tbuf *data)
{
	txn->op = op;
	txn->req = (struct tbuf) {
		.data = data->data,
		.size = data->size,
		.capacity = data->size,
		.pool = NULL };
}

static void
txn_cleanup(struct box_txn *txn)
{
	struct box_tuple **tuple = txn->ref_tuples->data;
	int i = txn->ref_tuples->size / sizeof(struct box_txn *);

	while (i-- > 0) {
		say_debug("tuple_txn_unref(%p)", *tuple);
		tuple_ref(*tuple++, -1);
	}

	/* mark txn as clean */
	memset(txn, 0, sizeof(*txn));
}

void
txn_commit(struct box_txn *txn)
{
	assert(txn == in_txn());
	assert(txn->op);

	if (!op_is_select(txn->op)) {
		say_debug("box_commit(op:%s)", messages_strs[txn->op]);

		if (txn->flags & BOX_NOT_STORE)
			;
		else {
			fiber_peer_name(fiber); /* fill the cookie */
			struct tbuf *t = tbuf_alloc(fiber->gc_pool);
			tbuf_append(t, &txn->op, sizeof(txn->op));
			tbuf_append(t, txn->req.data, txn->req.size);

			i64 lsn = next_lsn(recovery_state, 0);
			bool res = !wal_write(recovery_state, wal_tag,
					      fiber->cookie, lsn, t);
			confirm_lsn(recovery_state, lsn);
			if (res)
				tnt_raise(LoggedError, :ER_WAL_IO);
		}

		unlock_tuples(txn);

		if (txn->op == DELETE_1_3 || txn->op == DELETE)
			commit_delete(txn);
		else
			commit_replace(txn);
	}
	/*
	 * If anything above throws, we must be able to
	 * roll back. Thus clear mod_data.txn only when
	 * we know for sure the commit has succeeded.
	 */
	fiber->mod_data.txn = 0;

	if (txn->flags & BOX_GC_TXN)
		fiber_register_cleanup((fiber_cleanup_handler)txn_cleanup, txn);
	else
		txn_cleanup(txn);
}

void
txn_rollback(struct box_txn *txn)
{
	assert(txn == in_txn());
	fiber->mod_data.txn = 0;
	if (txn->op == 0)
		return;

	if (!op_is_select(txn->op)) {
		say_debug("txn_rollback(op:%s)", messages_strs[txn->op]);

		unlock_tuples(txn);

		if (txn->op == REPLACE)
			rollback_replace(txn);
	}

	txn_cleanup(txn);
}

static void
box_dispatch(struct box_txn *txn, struct tbuf *data)
{
	u32 cardinality;
	void *key;
	u32 key_len;

	say_debug("box_dispatch(%i)", txn->op);

	switch (txn->op) {
	case REPLACE:
		txn_assign_n(txn, data);
		txn->flags |= read_u32(data) & BOX_ALLOWED_REQUEST_FLAGS;
		cardinality = read_u32(data);
		if (space[txn->n].cardinality > 0
		    && space[txn->n].cardinality != cardinality)
			tnt_raise(IllegalParams, :"tuple cardinality must match space cardinality");
		prepare_replace(txn, cardinality, data);
		break;

	case DELETE:
	case DELETE_1_3:
		txn_assign_n(txn, data);
		if (txn->op == DELETE)
			txn->flags |= read_u32(data) & BOX_ALLOWED_REQUEST_FLAGS;
		key_len = read_u32(data);
		if (key_len != 1)
			tnt_raise(IllegalParams, :"key must be single valued");

		key = read_field(data);
		if (data->size != 0)
			tnt_raise(IllegalParams, :"can't unpack request");

		prepare_delete(txn, key);
		break;

	case SELECT:
	{
		txn_assign_n(txn, data);
		u32 i = read_u32(data);
		u32 offset = read_u32(data);
		u32 limit = read_u32(data);

		if (i >= BOX_INDEX_MAX || space[txn->n].index[i] == nil)
			tnt_raise(LoggedError, :ER_NO_SUCH_INDEX, i, txn->n);
		txn->index = space[txn->n].index[i];

		process_select(txn, limit, offset, data);
		break;
	}

	case UPDATE:
		txn_assign_n(txn, data);
		txn->flags |= read_u32(data) & BOX_ALLOWED_REQUEST_FLAGS;
		prepare_update(txn, data);
		break;
	case CALL:
		txn->flags |= read_u32(data) & BOX_ALLOWED_REQUEST_FLAGS;
		box_lua_call(txn, data);
		break;

	default:
		say_error("box_dispatch: unsupported command = %" PRIi32 "", txn->op);
		tnt_raise(IllegalParams, :"unsupported command code, check the error log");
	}
}

static int
box_xlog_sprint(struct tbuf *buf, const struct tbuf *t)
{
	struct row_v11 *row = row_v11(t);

	struct tbuf *b = palloc(fiber->gc_pool, sizeof(*b));
	b->data = row->data;
	b->size = row->len;
	u16 tag, op;
	u64 cookie;
	struct sockaddr_in *peer = (void *)&cookie;

	u32 n, key_len;
	void *key;
	u32 cardinality, field_no;
	u32 flags;
	u32 op_cnt;

	tbuf_printf(buf, "lsn:%" PRIi64 " ", row->lsn);

	say_debug("b->len:%" PRIu32, b->size);

	tag = read_u16(b);
	cookie = read_u64(b);
	op = read_u16(b);
	n = read_u32(b);

	tbuf_printf(buf, "tm:%.3f t:%" PRIu16 " %s:%d %s n:%i",
		    row->tm, tag, inet_ntoa(peer->sin_addr), ntohs(peer->sin_port),
		    messages_strs[op], n);

	switch (op) {
	case REPLACE:
		flags = read_u32(b);
		cardinality = read_u32(b);
		if (b->size != valid_tuple(b, cardinality))
			abort();
		tuple_print(buf, cardinality, b->data);
		break;

	case DELETE:
		flags = read_u32(b);
	case DELETE_1_3:
		key_len = read_u32(b);
		key = read_field(b);
		if (b->size != 0)
			abort();
		tuple_print(buf, key_len, key);
		break;

	case UPDATE:
		flags = read_u32(b);
		key_len = read_u32(b);
		key = read_field(b);
		op_cnt = read_u32(b);

		tbuf_printf(buf, "flags:%08X ", flags);
		tuple_print(buf, key_len, key);

		while (op_cnt-- > 0) {
			field_no = read_u32(b);
			u8 op = read_u8(b);
			void *arg = read_field(b);

			tbuf_printf(buf, " [field_no:%i op:", field_no);
			switch (op) {
			case 0:
				tbuf_printf(buf, "set ");
				break;
			case 1:
				tbuf_printf(buf, "add ");
				break;
			case 2:
				tbuf_printf(buf, "and ");
				break;
			case 3:
				tbuf_printf(buf, "xor ");
				break;
			case 4:
				tbuf_printf(buf, "or ");
				break;
			}
			tuple_print(buf, 1, arg);
			tbuf_printf(buf, "] ");
		}
		break;
	default:
		tbuf_printf(buf, "unknown wal op %" PRIi32, op);
	}
	return 0;
}


static int
snap_print(struct recovery_state *r __attribute__((unused)), struct tbuf *t)
{
	struct tbuf *out = tbuf_alloc(t->pool);
	struct box_snap_row *row;
	struct row_v11 *raw_row = row_v11(t);

	struct tbuf *b = palloc(fiber->gc_pool, sizeof(*b));
	b->data = raw_row->data;
	b->size = raw_row->len;

	(void)read_u16(b); /* drop tag */
	(void)read_u64(b); /* drop cookie */

	row = box_snap_row(b);

	tuple_print(out, row->tuple_size, row->data);
	printf("n:%i %*s\n", row->space, (int) out->size, (char *)out->data);
	return 0;
}

static int
xlog_print(struct recovery_state *r __attribute__((unused)), struct tbuf *t)
{
	struct tbuf *out = tbuf_alloc(t->pool);
	int res = box_xlog_sprint(out, t);
	if (res >= 0)
		printf("%*s\n", (int)out->size, (char *)out->data);
	return res;
}

void
space_free(void)
{
	int i;
	for (i = 0 ; i < BOX_SPACE_MAX ; i++) {
		if (!space[i].enabled)
			continue;
		int j;
		for (j = 0 ; j < BOX_INDEX_MAX ; j++) {
			Index *index = space[i].index[j];
			if (index == nil)
				break;
			[index free];
		}
	}
}

static void
key_init(struct key_def *def, struct tarantool_cfg_space_index *cfg_index)
{
	def->max_fieldno = 0;
	def->part_count = 0;

	/* Calculate key cardinality and maximal field number. */
	for (int k = 0; cfg_index->key_field[k] != NULL; ++k) {
		typeof(cfg_index->key_field[k]) cfg_key = cfg_index->key_field[k];

		if (cfg_key->fieldno == -1) {
			/* last filled key reached */
			break;
		}

		def->max_fieldno = MAX(def->max_fieldno, cfg_key->fieldno);
		def->part_count++;
	}

	/* init def array */
	def->parts = salloc(sizeof(struct key_part) * def->part_count);
	if (def->parts == NULL) {
		panic("can't allocate def parts array for index");
	}

	/* init compare order array */
	def->max_fieldno++;
	def->cmp_order = salloc(def->max_fieldno * sizeof(u32));
	if (def->cmp_order == NULL) {
		panic("can't allocate def cmp_order array for index");
	}
	memset(def->cmp_order, -1, def->max_fieldno * sizeof(u32));

	/* fill fields and compare order */
	for (int k = 0; cfg_index->key_field[k] != NULL; ++k) {
		typeof(cfg_index->key_field[k]) cfg_key = cfg_index->key_field[k];

		if (cfg_key->fieldno == -1) {
			/* last filled key reached */
			break;
		}

		/* fill keys */
		def->parts[k].fieldno = cfg_key->fieldno;
		def->parts[k].type = STR2ENUM(field_data_type, cfg_key->type);
		/* fill compare order */
		def->cmp_order[cfg_key->fieldno] = k;
	}
	def->is_unique = cfg_index->unique;
}

static void
space_config(void)
{
	/* exit if no spaces are configured */
	if (cfg.space == NULL) {
		return;
	}

	/* fill box spaces */
	for (int i = 0; cfg.space[i] != NULL; ++i) {
		tarantool_cfg_space *cfg_space = cfg.space[i];

		if (!CNF_STRUCT_DEFINED(cfg_space) || !cfg_space->enabled)
			continue;

		assert(cfg.memcached_port == 0 || i != cfg.memcached_space);

		space[i].enabled = true;

		space[i].cardinality = cfg_space->cardinality;
		/* fill space indexes */
		for (int j = 0; cfg_space->index[j] != NULL; ++j) {
			typeof(cfg_space->index[j]) cfg_index = cfg_space->index[j];
			struct key_def key_def;
			key_init(&key_def, cfg_index);
			enum index_type type = STR2ENUM(index_type, cfg_index->type);
			Index *index = [Index alloc: type :&key_def];
			[index init: type :&key_def:space + i :j];
			space[i].index[j] = index;
		}

		space[i].enabled = true;
		space[i].n = i;
		say_info("space %i successfully configured", i);
	}
}

void
space_init(void)
{
	/* Allocate and initialize space memory. */
	space = palloc(eter_pool, sizeof(struct space) * BOX_SPACE_MAX);
	memset(space, 0, sizeof(struct space) * BOX_SPACE_MAX);


	/* configure regular spaces */
	space_config();

	/* configure memcached space */
	memcached_space_init();
}

static void
box_process_rw(u32 op, struct tbuf *request_data)
{
	ev_tstamp start = ev_now(), stop;

	stat_collect(stat_base, op, 1);

	struct box_txn *txn = in_txn();
	if (txn == NULL) {
		txn = txn_begin();
		txn->flags |= BOX_GC_TXN;
		txn->out = &box_out_iproto;
	}

	@try {
		txn_set_op(txn, op, request_data);
		box_dispatch(txn, request_data);
		txn_commit(txn);
	}
	@catch (id e) {
		txn_rollback(txn);
		@throw;
	}
	@finally {
		stop = ev_now();
		if (stop - start > cfg.too_long_threshold)
			say_warn("too long %s: %.3f sec", messages_strs[op], stop - start);
	}
}

static void
box_process_ro(u32 op, struct tbuf *request_data)
{
	if (!op_is_select(op)) {
		struct box_txn *txn = in_txn();
		if (txn != NULL)
			txn_rollback(txn);
		tnt_raise(LoggedError, :ER_NONMASTER);
	}

	return box_process_rw(op, request_data);
}

static struct tbuf *
convert_snap_row_to_wal(struct tbuf *t)
{
	struct tbuf *r = tbuf_alloc(fiber->gc_pool);
	struct box_snap_row *row = box_snap_row(t);
	u16 op = REPLACE;
	u32 flags = 0;

	tbuf_append(r, &op, sizeof(op));
	tbuf_append(r, &row->space, sizeof(row->space));
	tbuf_append(r, &flags, sizeof(flags));
	tbuf_append(r, &row->tuple_size, sizeof(row->tuple_size));
	tbuf_append(r, row->data, row->data_size);

	return r;
}

static int
recover_row(struct recovery_state *r __attribute__((unused)), struct tbuf *t)
{
	/* drop wal header */
	if (tbuf_peek(t, sizeof(struct row_v11)) == NULL)
		return -1;

	u16 tag = read_u16(t);
	read_u64(t); /* drop cookie */
	if (tag == snap_tag)
		t = convert_snap_row_to_wal(t);
	else if (tag != wal_tag) {
		say_error("unknown row tag: %i", (int)tag);
		return -1;
	}

	u16 op = read_u16(t);

	struct box_txn *txn = txn_begin();
	txn->flags |= BOX_NOT_STORE;
	txn->out = &box_out_quiet;

	@try {
		box_process_rw(op, t);
	}
	@catch (id e) {
		return -1;
	}

	return 0;
}

static void
title(const char *fmt, ...)
{
	va_list ap;
	char buf[128], *bufptr = buf, *bufend = buf + sizeof(buf);

	va_start(ap, fmt);
	bufptr += vsnprintf(bufptr, bufend - bufptr, fmt, ap);
	va_end(ap);

	int ports[] = { cfg.primary_port, cfg.secondary_port,
			cfg.memcached_port, cfg.admin_port,
			cfg.replication_port };
	int *pptr = ports;
	char *names[] = { "pri", "sec", "memc", "adm", "rpl", NULL };
	char **nptr = names;

	for (; *nptr; nptr++, pptr++)
		if (*pptr)
			bufptr += snprintf(bufptr, bufend - bufptr,
					   " %s: %i", *nptr, *pptr);

	set_proc_title(buf);
}


static void
box_enter_master_or_replica_mode(struct tarantool_cfg *conf)
{
	if (conf->replication_source != NULL) {
		rw_callback = box_process_ro;

		recovery_wait_lsn(recovery_state, recovery_state->lsn);
		recovery_follow_remote(recovery_state, conf->replication_source);

		snprintf(status, sizeof(status), "replica/%s%s",
			 conf->replication_source, custom_proc_title);
		title("replica/%s%s", conf->replication_source, custom_proc_title);
	} else {
		rw_callback = box_process_rw;

		memcached_start_expire();

		snprintf(status, sizeof(status), "primary%s", custom_proc_title);
		title("primary%s", custom_proc_title);

		say_info("I am primary");
	}
}

static void
box_leave_local_standby_mode(void *data __attribute__((unused)))
{
	recover_finalize(recovery_state);

	box_enter_master_or_replica_mode(&cfg);
}

static i32
check_spaces(struct tarantool_cfg *conf)
{
	/* exit if no spaces are configured */
	if (conf->space == NULL) {
		return 0;
	}

	for (size_t i = 0; conf->space[i] != NULL; ++i) {
		typeof(conf->space[i]) space = conf->space[i];

		if (!CNF_STRUCT_DEFINED(space)) {
			/* space undefined, skip it */
			continue;
		}

		if (!space->enabled) {
			/* space disabled, skip it */
			continue;
		}

		/* check space bound */
		if (i >= BOX_SPACE_MAX) {
			/* maximum space is reached */
			out_warning(0, "(space = %zu) "
				    "too many spaces (%i maximum)", i, space);
			return -1;
		}

		if (conf->memcached_port && i == conf->memcached_space) {
			out_warning(0, "Space %i is already used as "
				    "memcached_space.", i);
			return -1;
		}

		/* at least one index in space must be defined
		 * */
		if (space->index == NULL) {
			out_warning(0, "(space = %zu) "
				    "at least one index must be defined", i);
			return -1;
		}

		/* check spaces indexes */
		for (size_t j = 0; space->index[j] != NULL; ++j) {
			typeof(space->index[j]) index = space->index[j];
			u32 index_cardinality = 0;
			enum index_type index_type;

			/* check index bound */
			if (j >= BOX_INDEX_MAX) {
				/* maximum index in space reached */
				out_warning(0, "(space = %zu index = %zu) "
					    "too many indexed (%i maximum)", i, j, BOX_INDEX_MAX);
				return -1;
			}

			/* at least one key in index must be defined */
			if (index->key_field == NULL) {
				out_warning(0, "(space = %zu index = %zu) "
					    "at least one field must be defined", i, j);
				return -1;
			}

			/* check unique property */
			if (index->unique == -1) {
				/* unique property undefined */
				out_warning(0, "(space = %zu index = %zu) "
					    "unique property is undefined", i, j);
			}

			for (size_t k = 0; index->key_field[k] != NULL; ++k) {
				typeof(index->key_field[k]) key = index->key_field[k];

				if (key->fieldno == -1) {
					/* last key reached */
					break;
				}

				/* key must has valid type */
				if (STR2ENUM(field_data_type, key->type) == field_data_type_MAX) {
					out_warning(0, "(space = %zu index = %zu) "
						    "unknown field data type: `%s'", i, j, key->type);
					return -1;
				}

				++index_cardinality;
			}

			/* check index cardinality */
			if (index_cardinality == 0) {
				out_warning(0, "(space = %zu index = %zu) "
					    "at least one field must be defined", i, j);
				return -1;
			}

			index_type = STR2ENUM(index_type, index->type);

			/* check index type */
			if (index_type == index_type_MAX) {
				out_warning(0, "(space = %zu index = %zu) "
					    "unknown index type '%s'", i, j, index->type);
				return -1;
			}

			/* first space index must be unique and cardinality == 1 */
			if (j == 0) {
				if (index->unique == false) {
					out_warning(0, "(space = %zu) space first index must be unique", i);
					return -1;
				}
				if (index_cardinality != 1) {
					out_warning(0, "(space = %zu) space first index must be single keyed", i);
					return -1;
				}
			}

			switch (index_type) {
			case HASH:
				/* check hash index */
				/* hash index must has single-field key */
				if (index_cardinality != 1) {
					out_warning(0, "(space = %zu index = %zu) "
					            "hash index must has a single-field key", i, j);
					return -1;
				}
				/* hash index must be unique */
				if (!index->unique) {
					out_warning(0, "(space = %zu index = %zu) "
					            "hash index must be unique", i, j);
					return -1;
				}
				break;
			case TREE:
				/* extra check for tree index not needed */
				break;
			default:
				assert(false);
			}
		}
	}

	return 0;
}

i32
mod_check_config(struct tarantool_cfg *conf)
{
	/* replication & hot standby modes can not work together */
	if (conf->replication_source != NULL && conf->local_hot_standby > 0) {
		out_warning(0, "replication and local hot standby modes "
			       "can't be enabled simultaneously");
		return -1;
	}

	/* check replication mode */
	if (conf->replication_source != NULL) {
		/* check replication port */
		char ip_addr[32];
		int port;

		if (sscanf(conf->replication_source, "%31[^:]:%i",
			   ip_addr, &port) != 2) {
			out_warning(0, "replication source IP address is not recognized");
			return -1;
		}
		if (port <= 0 || port >= USHRT_MAX) {
			out_warning(0, "invalid replication source port value: %i", port);
			return -1;
		}
	}

	/* check primary port */
	if (conf->primary_port != 0 &&
	    (conf->primary_port <= 0 || conf->primary_port >= USHRT_MAX)) {
		out_warning(0, "invalid primary port value: %i", conf->primary_port);
		return -1;
	}

	/* check secondary port */
	if (conf->secondary_port != 0 &&
	    (conf->secondary_port <= 0 || conf->secondary_port >= USHRT_MAX)) {
		out_warning(0, "invalid secondary port value: %i", conf->primary_port);
		return -1;
	}

	/* check if at least one space is defined */
	if (conf->space == NULL && conf->memcached_port == 0) {
		out_warning(0, "at least one space or memcached port must be defined");
		return -1;
	}

	/* check configured spaces */
	if (check_spaces(conf) != 0) {
		return -1;
	}

	/* check memcached configuration */
	if (memcached_check_config(conf) != 0) {
		return -1;
	}

	return 0;
}

i32
mod_reload_config(struct tarantool_cfg *old_conf, struct tarantool_cfg *new_conf)
{
	bool old_is_replica = old_conf->replication_source != NULL;
	bool new_is_replica = new_conf->replication_source != NULL;

	if (old_is_replica != new_is_replica ||
	    (old_is_replica &&
	     (strcmp(old_conf->replication_source, new_conf->replication_source) != 0))) {

		if (recovery_state->finalize != true) {
			out_warning(0, "Could not propagate %s before local recovery finished",
				    old_is_replica == true ? "slave to master" :
				    "master to slave");

			return -1;
		}

		if (!old_is_replica && new_is_replica)
			memcached_stop_expire();

		if (recovery_state->remote_recovery)
			recovery_stop_remote(recovery_state);

		box_enter_master_or_replica_mode(new_conf);
	}

	return 0;
}

void
mod_free(void)
{
	space_free();
	memcached_free();
}

void
mod_init(void)
{
	static iproto_callback ro_callback = box_process_ro;

	title("loading");
	atexit(mod_free);

	box_lua_init();

	/* initialization spaces */
	space_init();

	/* recovery initialization */
	recovery_state = recover_init(cfg.snap_dir, cfg.wal_dir,
				      recover_row, cfg.rows_per_wal, cfg.wal_fsync_delay,
				      cfg.wal_writer_inbox_size,
				      init_storage ? RECOVER_READONLY : 0, NULL);

	recovery_state->snap_io_rate_limit = cfg.snap_io_rate_limit * 1024 * 1024;
	recovery_setup_panic(recovery_state, cfg.panic_on_snap_error, cfg.panic_on_wal_error);

	stat_base = stat_register(messages_strs, messages_MAX);

	/* memcached initialize */
	memcached_init();


	if (init_storage)
		return;

	recover(recovery_state, 0);
	stat_cleanup(stat_base, messages_MAX);

	title("building indexes");

	build_indexes();

	title("orphan");

	if (cfg.local_hot_standby) {
		say_info("starting local hot standby");
		recover_follow(recovery_state, cfg.wal_dir_rescan_delay);
		snprintf(status, sizeof(status), "hot_standby");
		title("hot_standby");
	}

	/* run primary server */
	if (cfg.primary_port != 0)
		fiber_server("primary", cfg.primary_port,
			     (fiber_server_callback) iproto_interact,
			     &rw_callback, box_leave_local_standby_mode);

	/* run secondary server */
	if (cfg.secondary_port != 0)
		fiber_server("secondary", cfg.secondary_port,
			     (fiber_server_callback) iproto_interact,
			     &ro_callback, NULL);

	/* run memcached server */
	if (cfg.memcached_port != 0)
		fiber_server("memcached", cfg.memcached_port,
			     memcached_handler, NULL, NULL);
}

int
mod_cat(const char *filename)
{
	return read_log(filename, xlog_print, snap_print, NULL);
}

static void
snapshot_write_tuple(struct log_io_iter *i, unsigned n, struct box_tuple *tuple)
{
	struct tbuf *row;
	struct box_snap_row header;

	if (tuple->flags & GHOST)	// do not save fictive rows
		return;

	header.space = n;
	header.tuple_size = tuple->cardinality;
	header.data_size = tuple->bsize;

	row = tbuf_alloc(fiber->gc_pool);
	tbuf_append(row, &header, sizeof(header));
	tbuf_append(row, tuple->data, tuple->bsize);

	snapshot_write_row(i, snap_tag, default_cookie, row);
}

void
mod_snapshot(struct log_io_iter *i)
{
	struct box_tuple *tuple;

	for (uint32_t n = 0; n < BOX_SPACE_MAX; ++n) {
		if (!space[n].enabled)
			continue;

		Index *pk = space[n].index[0];

		struct iterator *it = pk->position;
		[pk initIterator: it];
		while ((tuple = it->next(it))) {
			snapshot_write_tuple(i, n, tuple);
		}
	}
}

void
mod_info(struct tbuf *out)
{
	tbuf_printf(out, "  version: \"%s\"" CRLF, tarantool_version());
	tbuf_printf(out, "  uptime: %i" CRLF, (int)tarantool_uptime());
	tbuf_printf(out, "  pid: %i" CRLF, getpid());
	tbuf_printf(out, "  wal_writer_pid: %" PRIi64 CRLF,
		    (i64) recovery_state->wal_writer->pid);
	tbuf_printf(out, "  lsn: %" PRIi64 CRLF, recovery_state->confirmed_lsn);
	tbuf_printf(out, "  recovery_lag: %.3f" CRLF, recovery_state->recovery_lag);
	tbuf_printf(out, "  recovery_last_update: %.3f" CRLF,
		    recovery_state->recovery_last_update_tstamp);
	tbuf_printf(out, "  status: %s" CRLF, status);
}

#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include <limits.h>

#include <connector/c/include/tnt.h>
#include <util.h>
#include <errcode.h>

/*==========================================================================
 * test variables
 *==========================================================================*/

/** tarantool connector instance */
static struct tnt *tnt;

static char *long_string = "A long time ago, in a galaxy far, far away...\n"
			   "It is a period of civil war. Rebel\n"
			   "spaceships, striking from a hidden\n"
			   "base, have won their first victory\n"
			   "against the evil Galactic Empire.\n"
			   "During the battle, Rebel spies managed\n"
			   "to steal secret plans to the Empire's\n"
			   "ultimate weapon, the Death Star, an\n"
			   "armored space station with enough\n"
			   "power to destroy an entire planet.\n"
			   "Pursued by the Empire's sinister agents,\n"
			   "Princess Leia races home aboard her\n"
			   "starship, custodian of the stolen plans\n"
			   "that can save her people and restore\n"
			   "freedom to the galaxy....";

/*==========================================================================
 * function declaration
 *==========================================================================*/

/*--------------------------------------------------------------------------
 * tarantool management functions
 *--------------------------------------------------------------------------*/

/** insert tuple */
void
insert_tuple(struct tnt_tuple *tuple);

/** select tuple by key */
void
select_tuple(i32 key);

/** update fields */
void
update_fields(i32 key, struct tnt_update *update);

/** add update fields operation: set int32 */
void
update_fields_set_i32(struct tnt_update *update, i32 field, i32 value);

/** add update fields operation: set string */
void
update_fields_set_str(struct tnt_update *update, i32 field, char *str);

/** add update fields operation: splice string */
void
update_fields_splice_str(struct tnt_update *update, i32 field, i32 offset, i32 length, char *list);

/** add update fields operation: delete field */
void
update_fields_delete_field(struct tnt_update *update, i32 field);


/** receive reply from server */
void
recv_command(char *command);

/** print tuple */
void
print_tuple(struct tnt_tuple *tuple);

/*--------------------------------------------------------------------------
 * test suite functions
 *--------------------------------------------------------------------------*/

/** setup test suite */
void
test_suite_setup();

/** clean-up test suite */
void
test_suite_tear_down();

/** print error message and exit */
void
fail(char *msg);

/** print tarantool error message and exit */
void
fail_tnt_error(char *msg, int error_code);

/** print tarantool error message and exit */
void
fail_tnt_perror(char *msg);


/*--------------------------------------------------------------------------
 * test cases functions
 *--------------------------------------------------------------------------*/

/** update fields test case: simple set operation test */
void
test_simple_set();

/** update fields test case: long set operation test */
void
test_long_set();

/** update fields test case: append(set) operation test */
void
test_append();

/** update fields test case: simple arithmetics operations test */
void
test_simple_arith();

/** update fields test case: multi arithmetics operations test */
void
test_multi_arith();

/** update fields test case: splice operations test */
void
test_splice();

/** update fields test case: set and spice operations test */
void
test_set_and_splice();

/** update fields test case: delete field operations test */
void
test_delete_field();


/*==========================================================================
 * function definition
 *==========================================================================*/

int
main(void)
{
	/* initialize suite */
	test_suite_setup();
	/* run tests */
	test_simple_set();
	test_long_set();
	test_append();
	test_simple_arith();
	test_multi_arith();
	test_splice();
	test_set_and_splice();
	test_delete_field();
	/* clean-up suite */
	test_suite_tear_down();
	return EXIT_SUCCESS;
}


/*--------------------------------------------------------------------------
 * tarantool management functions
 *--------------------------------------------------------------------------*/

void
insert_tuple(struct tnt_tuple *tuple)
{
	if (tnt_insert(tnt, 0, 0, TNT_PROTO_FLAG_RETURN, tuple) < 0)
		fail_tnt_perror("tnt_insert");
	recv_command("insert");
}

void
select_tuple(i32 key)
{
	struct tnt_tuples tuple_list;
	tnt_tuples_init(&tuple_list);
	struct tnt_tuple *tuple = tnt_tuples_add(&tuple_list);
	tnt_tuplef(tuple, "%d", key);

	if (tnt_select(tnt, 0, 0, 0, 0, 1, &tuple_list) == -1)
		fail_tnt_perror("select");
	recv_command("select");

	tnt_tuples_free(&tuple_list);
}

void
update_fields(i32 key, struct tnt_update *update)
{
	if (tnt_update(tnt, 0, 0, TNT_PROTO_FLAG_RETURN, (char *)&key, sizeof(key), update) < 0)
		fail_tnt_perror("tnt_update");
	recv_command("update fields");
}

void
update_fields_set_i32(struct tnt_update *update, i32 field, i32 value)
{
	int result = tnt_update_assign(update, field, (char *)&value, sizeof(value));
	if (result != 0)
		fail_tnt_error("tnt_update_assign", result);
}

void
update_fields_set_str(struct tnt_update *update, i32 field, char *str)
{
	int result = tnt_update_assign(update, field, str, strlen(str));
	if (result != 0)
		fail_tnt_error("tnt_update_delete_field", result);
}

void
update_fields_splice_str(struct tnt_update *update, i32 field, i32 offset, i32 length, char *list)
{
	int result = tnt_update_splice(update, field, offset, length, list, strlen(list));
	if (result != 0)
		fail_tnt_error("tnt_update_splice", result);
}

void
update_fields_delete_field(struct tnt_update *update, i32 field)
{
	int result = tnt_update_delete_field(update, field);
	if (result != 0)
		fail_tnt_error("tnt_update_delete_field", result);
}

void
recv_command(char *command)
{
	struct tnt_recv recv;

	tnt_recv_init(&recv);
	if (tnt_recv(tnt, &recv) < 0)
		fail_tnt_perror("tnt_recv");

	/* print reply header */
	printf("%s: respond %s (op: %d, reqid: %d, code: %d, count: %d)\n",
		command, tnt_strerror(tnt), TNT_RECV_OP(&recv), TNT_RECV_ID(&recv),
		TNT_RECV_CODE(&recv), TNT_RECV_COUNT(&recv));
	/* print tuples */
	struct tnt_tuple *tuple;
	TNT_RECV_FOREACH(&recv, tuple)
		print_tuple(tuple);

	tnt_recv_free(&recv);
}

void
print_tuple(struct tnt_tuple *tuple)
{
	bool is_first = true;

	struct tnt_tuple_field *field;
	printf("(");
	TNT_TUPLE_FOREACH(tuple, field) {

		if (!is_first) {
			printf(", ");
		}
		is_first = false;

		switch(field->size)
		{
		case 1:
			printf("%"PRIi8" (0x%02"PRIx8")", *(i8 *)field->data, *(i8 *)field->data);
			break;
		case 2:
			printf("%"PRIi16" (0x%04"PRIx16")", *(i16 *)field->data, *(i16 *)field->data);
			break;
		case 4:
			printf("%"PRIi32" (0x%08"PRIx32")", *(i32 *)field->data, *(i32 *)field->data);
			break;
		case 8:
			printf("%"PRIi64" (0x%016"PRIx64")", *(i64 *)field->data, *(i64 *)field->data);
			break;
		default:
			printf("'%.*s'", field->size, field->data);
			break;
		}
	}
	printf(")\n");
}


/*--------------------------------------------------------------------------
 * test suite functions
 *--------------------------------------------------------------------------*/

void
test_suite_setup()
{
	tnt = tnt_alloc();
	if (tnt == NULL) {
		fail("tnt_alloc");
	}

	tnt_set(tnt, TNT_OPT_HOSTNAME, "localhost");
	tnt_set(tnt, TNT_OPT_PORT, 33013);

	if (tnt_init(tnt) == -1)
		fail_tnt_perror("tnt_init");

	if (tnt_connect(tnt) == -1)
		fail_tnt_perror("tnt_connect");
}

void
test_suite_tear_down()
{
	tnt_free(tnt);
}

void
fail(char *msg)
{
	printf("fail: %s\n", msg);
	exit(EXIT_FAILURE);
}

void
fail_tnt_error(char *msg, int error_code)
{
	printf("fail: %s: %i\n", msg, error_code);
	exit(EXIT_FAILURE);
}

void
fail_tnt_perror(char *msg)
{
	printf("fail: %s: %s\n", msg, tnt_strerror(tnt));
	exit(EXIT_FAILURE);
}


/*--------------------------------------------------------------------------
 * test cases functions
 *--------------------------------------------------------------------------*/

void
test_simple_set()
{
	struct tnt_tuple tuple;
	struct tnt_update update;

	printf(">>> test simple set\n");

	/* insert tuple */
	printf("# insert tuple\n");
	tnt_tuple_init(&tuple);
	tnt_tuplef(&tuple, "%d%d%d%s", 1, 2, 0, "");
	insert_tuple(&tuple);
	tnt_tuple_free(&tuple);

	/* test simple set field */
	printf("# test simple set field\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 1, "new field value");
	update_fields_set_str(&update, 2, "");
	update_fields_set_str(&update, 3, "fLaC");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test useless set operations */
	printf("# set field\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 1, "value?");
	update_fields_set_str(&update, 1, "very very very very very long field value?");
	update_fields_set_str(&update, 1, "field's new value");
	update_fields(1, &update);
	tnt_update_free(&update);

	printf("<<< test simple set done\n");
}

void
test_long_set()
{
	struct tnt_tuple tuple;
	struct tnt_update update;

	printf(">>> test long set\n");

	/* insert tuple */
	printf("# insert tuple\n");
	tnt_tuple_init(&tuple);
	tnt_tuplef(&tuple, "%d%s%s%s", 1, "first", "", "third");
	insert_tuple(&tuple);
	tnt_tuple_free(&tuple);

	/* test set long value in empty field */
	printf("# test set big value in empty field\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 2, long_string);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test replace long value to short */
	printf("# test replace long value to short\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 2, "short string");
	update_fields(1, &update);
	tnt_update_free(&update);

	printf("<<< test long set done\n");
}

void
test_append()
{
	struct tnt_tuple tuple;
	struct tnt_update update;

	printf(">>> test append\n");

	/* insert tuple */
	printf("# insert tuple\n");
	tnt_tuple_init(&tuple);
	tnt_tuplef(&tuple, "%d%s", 1, "first");
	insert_tuple(&tuple);
	tnt_tuple_free(&tuple);

	/* test append field */
	printf("# test append field\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 2, "second");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test multi append field */
	printf("# test multi append\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 3, "3");
	update_fields_set_str(&update, 3, "new field value");
	update_fields_set_str(&update, 3, "other new field value");
	update_fields_set_str(&update, 3, "third");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test append many field */
	printf("# test append many fields\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 4, "fourth");
	update_fields_set_str(&update, 5, "fifth");
	update_fields_set_str(&update, 6, "sixth");
	update_fields_set_str(&update, 7, "seventh");
	update_fields_set_str(&update, 8, long_string);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test append and change field */
	printf("# test append and change field\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 9, long_string);
	update_fields_splice_str(&update, 9, 1, 544, "ac");
	tnt_update_arith(&update, 9, TNT_UPDATE_XOR, 0x3ffffff);
	tnt_update_arith(&update, 9, TNT_UPDATE_ADD, 1024);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test set to not an exist field */
	printf("# test set to not an exist field\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 0xDEADBEEF, "invalid!");
	update_fields(1, &update);
	tnt_update_free(&update);

	printf("<<< test append done\n");
}

void
test_simple_arith()
{
	struct tnt_tuple tuple;
	struct tnt_update update;

	printf(">>> test simple arith\n");

	/* insert tuple */
	printf("# insert tuple\n");
	tnt_tuple_init(&tuple);
	tnt_tuplef(&tuple, "%d%d%d%d", 1, 2, 0, 0);
	insert_tuple(&tuple);
	tnt_tuple_free(&tuple);

	/* test simple add */
	printf("# test simple add\n");
	tnt_update_init(&update);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 16);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test overflow add */
	printf("# test overflow add\n");
	tnt_update_init(&update);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, INT_MAX);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test overflow add */
	printf("# test underflow add\n");
	tnt_update_init(&update);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, INT_MIN);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test or */
	printf("# test simple or\n");
	tnt_update_init(&update);
	tnt_update_arith(&update, 2, TNT_UPDATE_OR, 0xbacf);
	tnt_update_arith(&update, 3, TNT_UPDATE_OR, 0xfabc);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test xor */
	printf("# test simple xor\n");
	tnt_update_init(&update);
	tnt_update_arith(&update, 2, TNT_UPDATE_XOR, 0xffff);
	tnt_update_arith(&update, 3, TNT_UPDATE_XOR, 0xffff);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test and */
	printf("# test simple and\n");
	tnt_update_init(&update);
	tnt_update_arith(&update, 2, TNT_UPDATE_AND, 0xf0f0);
	tnt_update_arith(&update, 3, TNT_UPDATE_AND, 0x0f0f);
	update_fields(1, &update);
	tnt_update_free(&update);

	printf("<<< test simple arith done\n");
}

void
test_multi_arith()
{
	printf(">>> test multi splice\n");

	struct tnt_tuple tuple;
	struct tnt_update update;
	/* insert tuple */
	printf("# insert tuple\n");
	tnt_tuple_init(&tuple);
	tnt_tuplef(&tuple, "%d%s%d%s", 1, "first", 128, "third");
	insert_tuple(&tuple);
	tnt_tuple_free(&tuple);

	/* test and */
	printf("# test simple and\n");
	tnt_update_init(&update);
	update_fields_set_i32(&update, 2, 0);
	update_fields_set_str(&update, 1, "first field new value");
	tnt_update_arith(&update, 2, TNT_UPDATE_XOR, 0xF00F);
	update_fields_set_str(&update, 3, "third field new value");
	tnt_update_arith(&update, 2, TNT_UPDATE_OR, 0xF00F);
	update_fields(1, &update);
	tnt_update_free(&update);

	printf("<<< test multi arith done\n");
}

void
test_splice()
{
	printf(">>> test simple splice\n");

	struct tnt_tuple tuple;
	struct tnt_update update;
	/* insert tuple */
	printf("# insert tuple\n");
	tnt_tuple_init(&tuple);
	tnt_tuplef(&tuple, "%d%s%s%s", 1, "first", "hi, this is a test string!", "third");
	insert_tuple(&tuple);
	tnt_tuple_free(&tuple);

	/* test cut from begin */
	printf("# test cut from begin\n");
	tnt_update_init(&update);
	update_fields_splice_str(&update, 2, 0, 4, "");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test cut from middle */
	printf("# test cut from middle\n");
	tnt_update_init(&update);
	update_fields_splice_str(&update, 2, 9, -8, "");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test cut from end */
	printf("# test cut from end\n");
	tnt_update_init(&update);
	update_fields_splice_str(&update, 2, -1, 1, "");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test insert before begin */
	printf("# test insert before begin\n");
	tnt_update_init(&update);
	update_fields_splice_str(&update, 2, 0, 0, "Bonjour, ");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test insert  */
	printf("# test insert after end\n");
	tnt_update_init(&update);
	update_fields_splice_str(&update, 2, 10000, 0, " o_O!?");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test replace in begin */
	printf("# test replace in begin\n");
	tnt_update_init(&update);
	update_fields_splice_str(&update, 2, 0, 7, "Hello");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test replace in middle */
	printf("# test replace in middle\n");
	tnt_update_init(&update);
	update_fields_splice_str(&update, 2, 17, -6, "field");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test replace in end */
	printf("# test replace in end\n");
	tnt_update_init(&update);
	update_fields_splice_str(&update, 2, -6, 4, "! Is this Sparta");
	update_fields(1, &update);
	tnt_update_free(&update);

	printf("<<< test simple splice done\n");
}

void
test_set_and_splice()
{
	printf(">>> test set and splice\n");

	struct tnt_tuple tuple;
	struct tnt_update update;
	/* insert tuple */
	printf("# insert tuple\n");
	tnt_tuple_init(&tuple);
	tnt_tuplef(&tuple, "%d%s%s%s", 1, "first", "hi, this is a test string!", "third");
	insert_tuple(&tuple);
	tnt_tuple_free(&tuple);

	/* test set long string and splice to short */
	printf("# test set long string and splice to short\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 2, long_string);
	update_fields_splice_str(&update, 2, 45, 500, " away away away");
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test set short value and splice to long */
	printf("# test set short value and splice to long\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 2, "test");
	update_fields_splice_str(&update, 2, -4, 4, long_string);
	update_fields(1, &update);
	tnt_update_free(&update);

	printf("<<< test set and splice done\n");
}

/** update fields test case: delete field operations test */
void
test_delete_field()
{
	printf(">>> test delete field\n");

	struct tnt_tuple tuple;
	struct tnt_update update;
	/* insert tuple */
	printf("# insert tuple\n");
	tnt_tuple_init(&tuple);
	tnt_tuplef(&tuple, "%d%s%s%s%d%d%d%d%d%d%d%d%d%d", 1, "first", "hi, this is a test string!", "third", 1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
	insert_tuple(&tuple);
	tnt_tuple_free(&tuple);

	/* test simple delete fields */
	printf("# test simple delete fields\n");
	tnt_update_init(&update);
	update_fields_delete_field(&update, 2);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test useless operations with delete fields*/
	printf("# test useless operations with delete fields\n");
	tnt_update_init(&update);
	update_fields_set_i32(&update, 1, 0);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	update_fields_delete_field(&update, 1);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test multi delete fields */
	printf("# test multi delete fields\n");
	tnt_update_init(&update);
	update_fields_delete_field(&update, 2);
	update_fields_delete_field(&update, 3);
	update_fields_delete_field(&update, 4);
	update_fields_delete_field(&update, 5);
	update_fields_delete_field(&update, 6);
	update_fields_delete_field(&update, 7);
	update_fields_delete_field(&update, 8);
	update_fields_delete_field(&update, 9);
	update_fields_delete_field(&update, 10);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test delete and set */
	printf("# test multi delete fields\n");
	tnt_update_init(&update);
	update_fields_delete_field(&update, 1);
	update_fields_set_i32(&update, 1, 3);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	tnt_update_arith(&update, 1, TNT_UPDATE_ADD, 1);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test append and delete */
	printf("# test append and delete\n");
	tnt_update_init(&update);
	update_fields_set_str(&update, 3, "second");
	update_fields_delete_field(&update, 3);
	update_fields_set_str(&update, 3, "third");
	update_fields_set_str(&update, 4, "third");
	update_fields_delete_field(&update, 4);
	update_fields_set_str(&update, 4, "third");
	update_fields_set_str(&update, 4, "fourth");
	update_fields_set_str(&update, 5, "fifth");
	update_fields_set_str(&update, 6, "sixth");
	update_fields_set_str(&update, 7, "seventh");
	update_fields_set_str(&update, 8, "eighth");
	update_fields_set_str(&update, 9, "ninth");
	update_fields_delete_field(&update, 7);
	update_fields_delete_field(&update, 6);
	update_fields(1, &update);
	tnt_update_free(&update);

	/* test double delete */
	printf("# test double delete\n");
	tnt_update_init(&update);
	update_fields_delete_field(&update, 3);
	update_fields_delete_field(&update, 3);
	update_fields(1, &update);
	tnt_update_free(&update);
	select_tuple(1);

	/* test delete not an exist field */
	printf("# test delete not an exist field\n");
	tnt_update_init(&update);
	update_fields_delete_field(&update, 0xDEADBEEF);
	update_fields(1, &update);
	tnt_update_free(&update);
	select_tuple(1);

	printf("<<< test delete field done\n");
}


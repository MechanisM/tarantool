#ifndef TARANTOOL_PLUGIN_H_INCLUED
#define TARANTOOL_PLUGIN_H_INCLUED

/*
 * Copyright (C) 2011 Mail.RU
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

#define PLUGIN_SYM ("tnt_plugin")
#define PLUGIN_EXT (".so")

enum {
	PLUGIN_OTHER
};

#define PLUGIN_OTHER_IFVER (0)

struct plugin_if {
	int type;
	char *name;
	char *desc;
	char *author;
	unsigned int version_major;
	unsigned int version_minor;
	unsigned int version_if;
	int (*init)(void);
	void (*free)(void);
	void *iface;
};

struct plugin {
	struct plugin_if *pif;
	char *path;
	void *fd;
	STAILQ_ENTRY(plugin) next;
};

struct plugins {
	int count;
	STAILQ_HEAD(,plugin) list;
};

void plugin_init(void);
void plugin_free(void);

struct plugin *plugin_attach(char *path);
void plugin_attach_dir(char *path);

void plugin_print(void);

#endif /* TARANTOOL_PLUGIN_H_INCLUDED */

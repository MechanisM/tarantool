
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

#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <dlfcn.h>

#include <third_party/queue.h>

#include <say.h>
#include <plugin.h>

static struct plugins plugins;

void
plugin_init(void)
{
	plugins.count = 0;
	STAILQ_INIT(&plugins.list);
}

void
plugin_free(void)
{
	struct plugin *p, *pnext;
	STAILQ_FOREACH_SAFE(p, &plugins.list, next, pnext) {
		if (p->pif->free)
			p->pif->free();
		free(p->path);
		dlclose(p->fd);
	}
}

static void*
plugin_attach_ret(void *fd, char *path, char *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	char msg[1024];
	vsnprintf(msg, sizeof(msg), fmt, args);
	va_end(args);

	say_error("plugin %s: %s", path, msg);
	if (fd)
		dlclose(fd);
	return NULL;
}

struct plugin*
plugin_attach(char *path)
{
	void *fd = dlopen(path, RTLD_NOW);
	if (fd == NULL)
		return plugin_attach_ret(fd, path, "%s", dlerror());

	struct plugin_if *pif = dlsym(fd, PLUGIN_SYM);
	if (pif == NULL)
		return plugin_attach_ret(fd, path,
			"'%s' symbol not found", PLUGIN_SYM);

	if (pif->version_major != TARANTOOL_VERSION_MAJOR ||
	    pif->version_minor != TARANTOOL_VERSION_MINOR)
		return plugin_attach_ret(fd, path,
			"version mismatch");

	switch (pif->type) {
	case PLUGIN_OTHER:
		if (pif->version_if != PLUGIN_OTHER_IFVER)
			return plugin_attach_ret(fd, path,
				"if version mismatch");
		break;
	default:
		return plugin_attach_ret(fd, path,
			"unknown plugin type");
	}

	if (pif->init && pif->init() == -1)
		return plugin_attach_ret(fd, path,
			"initialization failed");

	struct plugin *p = malloc(sizeof(struct plugin));
	if (p == NULL)
		return plugin_attach_ret(fd, path,
			"memory allocation failure");
	p->pif = pif;
	p->fd = fd;
	p->path = strdup(path);
	if (p->path == NULL) {
		free(p);
		return plugin_attach_ret(fd, path,
			"memory allocation failure");
	}
	plugins.count++;
	STAILQ_INSERT_TAIL(&plugins.list, p, next);
	return p;
}

static int
plugin_is(char *path) {

	char *ptr = strrchr(path, '.');
	if (ptr == NULL)
		return 0;
	return (strcmp(ptr, PLUGIN_EXT) == 0);
}

void
plugin_attach_dir(char *path)
{
	DIR *dir = opendir(path);
	if (dir == NULL) {
		say_warn("failed to open plugin directory %s", path);
		return;
	}
	struct dirent *de;
	while ((de = readdir(dir))) {
		if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
			continue;
		if (!plugin_is(de->d_name))
			continue;
		char ppath[1024];
		snprintf(ppath, sizeof(ppath), "%s/%s", path, de->d_name);
		plugin_attach(ppath);
	}
	closedir(dir);
}

void
plugin_print(void)
{
	say_info("%d plugins loaded", plugins.count);
	struct plugin *p;
	STAILQ_FOREACH(p, &plugins.list, next)
		say_info("[plugin] %s: %s", p->pif->name, p->pif->desc);
}

#include "skynet.h"

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <assert.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define MEMORY_WARNING_REPORT (1024 * 1024 * 32)

/*  */
struct snlua {
	lua_State * L;
	struct skynet_context * ctx;
	size_t mem;
	size_t mem_report;
	size_t mem_limit;
};

// LUA_CACHELIB may defined in patched lua for shared proto
#ifdef LUA_CACHELIB

#define codecache luaopen_cache

#else

static int
cleardummy(lua_State *L) {
  return 0;
}

static int 
codecache(lua_State *L) {
	luaL_Reg l[] = {
		{ "clear", cleardummy },
		{ "mode", cleardummy },
		{ NULL, NULL },
	};
	luaL_newlib(L,l);
	lua_getglobal(L, "loadfile");
	lua_setfield(L, -2, "loadfile");
	return 1;
}

#endif

static int 
traceback (lua_State *L) {
	const char *msg = lua_tostring(L, 1);
	if (msg)
		luaL_traceback(L, L, msg, 1);
	else {
		lua_pushliteral(L, "(no error message)");
	}
	return 1;
}

static void
report_launcher_error(struct skynet_context *ctx) {
	// sizeof "ERROR" == 5
	skynet_sendname(ctx, 0, ".launcher", PTYPE_TEXT, 0, "ERROR", 5);
}



static const char *
optstring(struct skynet_context *ctx, const char *key, const char * str) {
	const char * ret = skynet_command(ctx, "GETENV", key);
	if (ret == NULL) {
		return str;
	}
	return ret;
}


/* 初始化lua服务 */
static int
init_cb(struct snlua *l, struct skynet_context *ctx, const char * args, size_t sz) {
	lua_State *L = l->L;
	l->ctx = ctx;
	lua_gc(L, LUA_GCSTOP, 0);//暂停gc操作
	lua_pushboolean(L, 1);  /* signal for libraries to ignore env. vars. */
	lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");/* registry["LUA_NOENV"]=1 */
	luaL_openlibs(L);/* 加载库 */
	lua_pushlightuserdata(L, ctx);//把服务上下文作为一个轻量级用户自定义数据保存到注册表中
	lua_setfield(L, LUA_REGISTRYINDEX, "skynet_context");/* registry["skynet_context"]=ctx  */
	luaL_requiref(L, "skynet.codecache", codecache , 0);/* 加载skynet.codecache */
	lua_pop(L,1);//

	/* 在snlua->L的虚拟机中设置全局变量值 */
	const char *path = optstring(ctx, "lua_path","./lualib/?.lua;./lualib/?/init.lua"); /* lua路径 */
	lua_pushstring(L, path);
	lua_setglobal(L, "LUA_PATH"); 
	const char *cpath = optstring(ctx, "lua_cpath","./luaclib/?.so");/* c路径 */
	lua_pushstring(L, cpath);
	lua_setglobal(L, "LUA_CPATH");
	const char *service = optstring(ctx, "luaservice", "./service/?.lua");/* lua服务路径 */
	lua_pushstring(L, service);
	lua_setglobal(L, "LUA_SERVICE");
	const char *preload = skynet_command(ctx, "GETENV", "preload");
	lua_pushstring(L, preload);
	lua_setglobal(L, "LUA_PRELOAD");/* 预加载路径 */

	lua_pushcfunction(L, traceback);
	assert(lua_gettop(L) == 1);

	const char * loader = optstring(ctx, "lualoader", "./lualib/loader.lua");

	int r = luaL_loadfile(L,loader); /* 加载loader.lua文件 */
	if (r != LUA_OK) {/* 加载失败 */
		skynet_error(ctx, "Can't load %s : %s", loader, lua_tostring(L, -1));
		report_launcher_error(ctx);
		return 1;
	}
	lua_pushlstring(L, args, sz);//把lua服务名作为参数执行loader.lua
	r = lua_pcall(L,1,0,1);/* 执行loader.lua，error func为traceback函数 */
	if (r != LUA_OK) {
		skynet_error(ctx, "lua loader error : %s", lua_tostring(L, -1));
		report_launcher_error(ctx);
		return 1;
	}
	lua_settop(L,0);
	if (lua_getfield(L, LUA_REGISTRYINDEX, "memlimit") == LUA_TNUMBER) {//读取lua虚拟机中设置的内存限制值
		size_t limit = lua_tointeger(L, -1);
		l->mem_limit = limit;
		skynet_error(ctx, "Set memory limit to %.2f M", (float)limit / (1024 * 1024));
		lua_pushnil(L);
		lua_setfield(L, LUA_REGISTRYINDEX, "memlimit");
	}
	lua_pop(L, 1);

	lua_gc(L, LUA_GCRESTART, 0);

	return 0;
}

/* 启动lua服务
 * @ud:sn_create创建的数据类型，此处为struct snlua  
 * @type:消息类型
 * @session:
 * @source:
 * @msg:消息数据
 * @sz：长度
 */
static int
launch_cb(struct skynet_context * context, void *ud, int type, int session, uint32_t source , const void * msg, size_t sz) {
	assert(type == 0 && session == 0);
	struct snlua *l = ud;/* 在snlua_init里，把context->cb_ud设置成了服务的上下文snlua */
	skynet_callback(context, NULL, NULL);//snlua服务只是lua服务的一层外皮，所以不需要消息处理函数，这样如果有误发到该服务的消息，work thread也能识并过滤掉
	int err = init_cb(l, context, msg, sz);//初始化lua服务
	if (err) {
		skynet_command(context, "EXIT", NULL);
	}

	return 0;
}

/* snlua服务的init函数 */
int
snlua_init(struct snlua *l, struct skynet_context *ctx, const char * args) {
	int sz = strlen(args);
	char * tmp = skynet_malloc(sz);
	memcpy(tmp, args, sz);
	skynet_callback(ctx, l , launch_cb);/* 把服务的消息处理函数设置为launch_cb函数， */
	const char * self = skynet_command(ctx, "REG", NULL);/* 调用REG命令，取本服务的handle的字符串值，返回值为":handle的16进制数" */
	uint32_t handle_id = strtoul(self+1, NULL, 16);/* self+1是为了跳过首字符，其为16进制标记字符X;字符串的字符为16进制数,此时handle_id=ctx->handle */

	// it must be first message
	skynet_send(ctx, 0, handle_id, PTYPE_TAG_DONTCOPY,0, tmp, sz);/* 向自己的消息队列push一条消息，消息内容为lua服务名 */
	return 0;
}

/* lua虚拟机使用的内存分配函数 */
static void *
lalloc(void * ud, void *ptr, size_t osize, size_t nsize) {
	struct snlua *l = ud;
	size_t mem = l->mem;
	l->mem += nsize;
	if (ptr)
		l->mem -= osize;/* 此时为realloc */

	if (l->mem_limit != 0 && l->mem > l->mem_limit) {/* 超出内存上限，不分配 */
		if (ptr == NULL || nsize > osize) {
			l->mem = mem;
			return NULL;
		}
	}

	if (l->mem > l->mem_report) {
		l->mem_report *= 2;
		skynet_error(l->ctx, "Memory warning %.2f M", (float)l->mem / (1024 * 1024));
	}
	return skynet_lalloc(ptr, osize, nsize);
}

/* snlua服务的create函数，用以创建服务使用的上下文 */
struct snlua *
snlua_create(void) {
	struct snlua * l = skynet_malloc(sizeof(*l));
	memset(l,0,sizeof(*l));
	l->mem_report = MEMORY_WARNING_REPORT;//内存警告值，32Mb
	l->mem_limit = 0;
	l->L = lua_newstate(lalloc, l);/* 单独使用一个虚拟机，虚拟机使用的内存分配函数为lalloc */
	return l;
}

void
snlua_release(struct snlua *l) {
	lua_close(l->L);
	skynet_free(l);
}

void
snlua_signal(struct snlua *l, int signal) {
	skynet_error(l->ctx, "recv a signal %d", signal);
	if (signal == 0) {
#ifdef lua_checksig
	// If our lua support signal (modified lua version by skynet), trigger it.
	skynet_sig_L = l->L;
#endif
	} else if (signal == 1) {
		skynet_error(l->ctx, "Current Memory %.3fK", (float)l->mem / 1024);
	}
}

/*
** $Id: lcorolib.c,v 1.10 2016/04/11 19:19:55 roberto Exp $
** Coroutine Library
** See Copyright Notice in lua.h
*/

#define lcorolib_c
#define LUA_LIB

#include "lprefix.h"


#include <stdlib.h>

#include "lua.h"

#include "lauxlib.h"
#include "lualib.h"


/* 获取参数里的lua_State */
static lua_State *getco (lua_State *L) {
  lua_State *co = lua_tothread(L, 1);
  luaL_argcheck(L, co, 1, "thread expected");
  return co;
}


/* @narg为coroutine.resume(co,...)的变参数量
 */
static int auxresume (lua_State *L, lua_State *co, int narg) {
  int status;
  if (!lua_checkstack(co, narg)) {
    lua_pushliteral(L, "too many arguments to resume");
    return -1;  /* error flag */
  }

  if (lua_status(co) == LUA_OK && lua_gettop(co) == 0) {/* co的栈上至少应有被唤醒函数 */
    lua_pushliteral(L, "cannot resume dead coroutine");
    return -1;  /* error flag */
  }
  lua_xmove(L, co, narg);/* 把所有变参复制到co的栈上 */
  /* 以上完成了唤醒co的条件 */

  status = lua_resume(co, L, narg);/* 调用唤醒函数 */
  if (status == LUA_OK || status == LUA_YIELD) /* yield状态时，coroutine.yield函数的栈帧未释放 */
  {
    int nres = lua_gettop(co);/* 返回值数量或者yiled函数传入的参数 */
    if (!lua_checkstack(L, nres + 1)) {
      lua_pop(co, nres);  /* remove results anyway */
      lua_pushliteral(L, "too many results to resume");
      return -1;  /* error flag */
    }
    lua_xmove(co, L, nres);  /* 把返回值赋值到主协程上，并返回 move yielded values */
    return nres;
  }
  else {
    lua_xmove(co, L, 1);  /* move error message */
    return -1;  /* error flag */
  }
}

/* coroutine.resume函数 */
static int luaB_coresume (lua_State *L) {
  lua_State *co = getco(L);/* 第一个参数为唤醒的协程 */
  int r;
  r = auxresume(L, co, lua_gettop(L) - 1);/* lua_gettop(L)-1为传递到唤醒协程的参数数量 */
  if (r < 0) {/* 运行时错误 */
    lua_pushboolean(L, 0);/* 插入false */
    lua_insert(L, -2);    /* 把false和errormsg调换位置 */
    return 2;             /* return false + error message */
  }
  else {
    lua_pushboolean(L, 1);/* 插入true */
    lua_insert(L, -(r + 1));
    return r + 1;  /* return true + 'resume' returns */
  }
}


static int luaB_auxwrap (lua_State *L) {
  lua_State *co = lua_tothread(L, lua_upvalueindex(1));
  int r = auxresume(L, co, lua_gettop(L));
  if (r < 0) {
    if (lua_type(L, -1) == LUA_TSTRING) {  /* error object is a string? */
      luaL_where(L, 1);  /* add extra info */
      lua_insert(L, -2);
      lua_concat(L, 2);
    }
    return lua_error(L);  /* propagate error */
  }
  return r;
}

/* coroutine.create(func())函数 */
static int luaB_cocreate (lua_State *L) {
  lua_State *NL;
  luaL_checktype(L, 1, LUA_TFUNCTION);
  NL = lua_newthread(L);/* 创建新的协程上下文 */
  lua_pushvalue(L, 1);  /* move function to top */
  lua_xmove(L, NL, 1);  /* move function from L to NL */
  return 1;/* 因为lua_newthread函数会把新建的协程压入栈，所以此时返回该协程 */
}


static int luaB_cowrap (lua_State *L) {
  luaB_cocreate(L);
  lua_pushcclosure(L, luaB_auxwrap, 1);
  return 1;
}


/* coroutine.yield函数 */
static int luaB_yield (lua_State *L) {
  return lua_yield(L, lua_gettop(L));
}


/* coroutine.status()函数 */
static int luaB_costatus (lua_State *L) {
  lua_State *co = getco(L);
  if (L == co)
	  lua_pushliteral(L, "running");
  else {
    switch (lua_status(co)) {
      case LUA_YIELD:
        lua_pushliteral(L, "suspended");
        break;
      case LUA_OK: {//
        lua_Debug ar;
        if (lua_getstack(co, 0, &ar) > 0)  /* does it have frames? */
          lua_pushliteral(L, "normal");  /* it is running */
        else if (lua_gettop(co) == 0)
            lua_pushliteral(L, "dead");
        else
          lua_pushliteral(L, "suspended");  /* initial state */
        break;
      }
      default:  /* some error occurred */
        lua_pushliteral(L, "dead");
        break;
    }
  }
  return 1;
}


/* 是否可让出执行 */
static int luaB_yieldable (lua_State *L) {
  lua_pushboolean(L, lua_isyieldable(L));
  return 1;
}

/* coroutine.running函数 */
static int luaB_corunning (lua_State *L) {
  int ismain = lua_pushthread(L);
  lua_pushboolean(L, ismain);
  return 2;/* 返回当前的协程、是否主协程 */
}


static const luaL_Reg co_funcs[] = {
  {"create", luaB_cocreate},
  {"resume", luaB_coresume},
  {"running", luaB_corunning},
  {"status", luaB_costatus},
  {"wrap", luaB_cowrap},
  {"yield", luaB_yield},
  {"isyieldable", luaB_yieldable},
  {NULL, NULL}
};



LUAMOD_API int luaopen_coroutine (lua_State *L) {
  luaL_newlib(L, co_funcs);
  return 1;
}


#include "skynet.h"

#include "skynet_module.h"
#include "spinlock.h"

#include <assert.h>
#include <string.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>

#define MAX_MODULE_TYPE 32

struct modules {
	int count;/*  */
	struct spinlock lock;
	const char * path;/* 库的加载路径 */
	struct skynet_module m[MAX_MODULE_TYPE];/* 预分配32个模块空间 */
};

static struct modules * M = NULL;

/* 加载库,库路径为m中的path路径,把字符?替换成库名name */
static void *
_try_open(struct modules *m, const char * name) {
	const char *l;
	const char * path = m->path;
	size_t path_size = strlen(path);
	size_t name_size = strlen(name);

	int sz = path_size + name_size;//库的完整
	//search path
	void * dl = NULL;
	char tmp[sz];
	do
	{
		memset(tmp,0,sz);
		while (*path == ';') /* 跳过开头的字符';' */
			path++;
		if (*path == '\0')//结尾
			break;
		l = strchr(path, ';');//搜索分割字符';'
		if (l == NULL) 
			l = path + strlen(path);//l指向动态库路径尾部
		int len = l - path;//路径长度
		int i;
		for (i=0;path[i]!='?' && i < len ;i++) {//把字符'?'前的路径copy到tmp临时路径中
			tmp[i] = path[i];
		}
		memcpy(tmp+i,name,name_size);//复制库名
		if (path[i] == '?') {//复制字符‘？’后的路径，一般未库的后缀信息
			strncpy(tmp+i+name_size,path+i+1,len - i - 1);
		} else {
			fprintf(stderr,"Invalid C service path\n");
			exit(1);
		}
		dl = dlopen(tmp, RTLD_NOW | RTLD_GLOBAL);//加载库，并且立即进行符号解析，并且允许后置动态库的引用
		path = l;
	}while(dl == NULL);

	if (dl == NULL) {
		fprintf(stderr, "try open %s failed : %s\n",name,dlerror());
	}

	return dl;//返回动态库的地址
}

/* 查找skynet_module是否已载入modules M */
static struct skynet_module * 
_query(const char * name) {
	int i;
	for (i=0;i<M->count;i++) {
		if (strcmp(M->m[i].name,name)==0) {
			return &M->m[i];
		}
	}
	return NULL;
}

/* 初始化module的函数指针create\init\release\signal */
static int
_open_sym(struct skynet_module *mod) {
	size_t name_size = strlen(mod->name);
	char tmp[name_size + 9]; // create/init/release/signal , longest name is release (7)
	memcpy(tmp, mod->name, name_size);
	strcpy(tmp+name_size, "_create");
	mod->create = dlsym(mod->module, tmp);
	strcpy(tmp+name_size, "_init");
	mod->init = dlsym(mod->module, tmp);
	strcpy(tmp+name_size, "_release");
	mod->release = dlsym(mod->module, tmp);
	strcpy(tmp+name_size, "_signal");
	mod->signal = dlsym(mod->module, tmp);

	return mod->init == NULL;
}

/* 查找skynet_module是否已加载 */
struct skynet_module * 
skynet_module_query(const char * name) {
	struct skynet_module * result = _query(name);
	if (result)
		return result;

	SPIN_LOCK(M)

	result = _query(name); // double check

	if (result == NULL && M->count < MAX_MODULE_TYPE) {
		int index = M->count;
		void * dl = _try_open(M,name);//加载动态库
		if (dl) {//在全局module管理表中管理该动态库的信息，包括name、hanndle、create\init\release\sigal四个动态函数
			M->m[index].name = name;
			M->m[index].module = dl;

			if (_open_sym(&M->m[index]) == 0) {/* 初始化skynet_module的函数 */
				M->m[index].name = skynet_strdup(name);
				M->count ++;
				result = &M->m[index];
			}
		}
	}

	SPIN_UNLOCK(M)

	return result;
}

void 
skynet_module_insert(struct skynet_module *mod) {
	SPIN_LOCK(M)

	struct skynet_module * m = _query(mod->name);
	assert(m == NULL && M->count < MAX_MODULE_TYPE);
	int index = M->count;
	M->m[index] = *mod;
	++M->count;

	SPIN_UNLOCK(M)
}

/* 调用库的create函数 */
void * 
skynet_module_instance_create(struct skynet_module *m) {
	if (m->create) {
		return m->create();
	} else {
		return (void *)(intptr_t)(~0);
	}
}

/* 调用模块的init函数，@inst为各actor的实际上下文结构，@parm为初始化参数 */
int
skynet_module_instance_init(struct skynet_module *m, void * inst, struct skynet_context *ctx, const char * parm) {
	return m->init(inst, ctx, parm);
}

void 
skynet_module_instance_release(struct skynet_module *m, void *inst) {
	if (m->release) {
		m->release(inst);
	}
}

void
skynet_module_instance_signal(struct skynet_module *m, void *inst, int signal) {
	if (m->signal) {
		m->signal(inst, signal);
	}
}


/* 初始化库storage，用于保存skynet_module */
void 
skynet_module_init(const char *path) {
	struct modules *m = skynet_malloc(sizeof(*m));
	m->count = 0;
	m->path = skynet_strdup(path);/* 用c开发的服务库的路径，默认为./cservice/?.so，？指代具体库文件名 */

	SPIN_INIT(m)

	M = m;
}

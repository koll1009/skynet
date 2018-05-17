#include "skynet.h"

#include "skynet_monitor.h"
#include "skynet_server.h"
#include "skynet.h"
#include "atomic.h"

#include <stdlib.h>
#include <string.h>

struct skynet_monitor {
	int version;
	int check_version;
	uint32_t source;
	uint32_t destination;
};

struct skynet_monitor * 
skynet_monitor_new() {
	struct skynet_monitor * ret = skynet_malloc(sizeof(*ret));
	memset(ret, 0, sizeof(*ret));
	return ret;
}

void 
skynet_monitor_delete(struct skynet_monitor *sm) {
	skynet_free(sm);
}

/* 多线程监视触发器 */
void 
skynet_monitor_trigger(struct skynet_monitor *sm, uint32_t source, uint32_t destination) {
	sm->source = source;
	sm->destination = destination;
	ATOM_INC(&sm->version);//每处理一条消息，version值递加
}


/* 多线程监视器检查 */
void 
skynet_monitor_check(struct skynet_monitor *sm) {
	/* work thread每调用一次消息处理函数之前会执行skynet_monitor_trigger，该函数会使得version递增，从而使第一次执行monitor check时，会执行
	 * 本函数的else语句，从而使得version==checkversion。当monitor thread再次执行monitor check时，version还是等于checkversion，说明消息处理函数还未执行完
	 * 而两次monitor check操作之间有5s的sleep，所以有endless loop的风险。
	 */
	if (sm->version == sm->check_version) {
		if (sm->destination) {//如果此时destination不为0，说明在消息处理函数中
			skynet_context_endless(sm->destination);
			skynet_error(NULL, "A message from [ :%08x ] to [ :%08x ] maybe in an endless loop (version = %d)", sm->source , sm->destination, sm->version);
		}
	} else {
		sm->check_version = sm->version;
	}
}

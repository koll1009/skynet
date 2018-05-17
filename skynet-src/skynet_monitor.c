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

/* ���̼߳��Ӵ����� */
void 
skynet_monitor_trigger(struct skynet_monitor *sm, uint32_t source, uint32_t destination) {
	sm->source = source;
	sm->destination = destination;
	ATOM_INC(&sm->version);//ÿ����һ����Ϣ��versionֵ�ݼ�
}


/* ���̼߳�������� */
void 
skynet_monitor_check(struct skynet_monitor *sm) {
	/* work threadÿ����һ����Ϣ������֮ǰ��ִ��skynet_monitor_trigger���ú�����ʹ��version�������Ӷ�ʹ��һ��ִ��monitor checkʱ����ִ��
	 * ��������else��䣬�Ӷ�ʹ��version==checkversion����monitor thread�ٴ�ִ��monitor checkʱ��version���ǵ���checkversion��˵����Ϣ��������δִ����
	 * ������monitor check����֮����5s��sleep��������endless loop�ķ��ա�
	 */
	if (sm->version == sm->check_version) {
		if (sm->destination) {//�����ʱdestination��Ϊ0��˵������Ϣ��������
			skynet_context_endless(sm->destination);
			skynet_error(NULL, "A message from [ :%08x ] to [ :%08x ] maybe in an endless loop (version = %d)", sm->source , sm->destination, sm->version);
		}
	} else {
		sm->check_version = sm->version;
	}
}

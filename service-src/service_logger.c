#include "skynet.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* logger����������Ľṹ�� */
struct logger {
	FILE * handle;//�ļ�������
	char * filename;//�ļ���
	int close;//��־λ����Ҫ�ֶ�close
};

/* ����logger����������� */
struct logger *
logger_create(void) {
	struct logger * inst = skynet_malloc(sizeof(*inst));
	inst->handle = NULL;
	inst->close = 0;
	inst->filename = NULL;

	return inst;
}

void
logger_release(struct logger * inst) {
	if (inst->close) {
		fclose(inst->handle);
	}
	skynet_free(inst->filename);
	skynet_free(inst);
}

/* logger�������Ϣ������ */
static int
logger_cb(struct skynet_context * context, void *ud, int type, int session, uint32_t source, const void * msg, size_t sz) {
	struct logger * inst = ud;
	switch (type) {
	case PTYPE_SYSTEM:
		if (inst->filename) {
			inst->handle = freopen(inst->filename, "a", inst->handle);
		}
		break;
	case PTYPE_TEXT:
		fprintf(inst->handle, "[:%08x] ",source);
		fwrite(msg, sz , 1, inst->handle);
		fprintf(inst->handle, "\n");
		fflush(inst->handle);
		break;
	}

	return 0;
}


/* logger module��init������@paramΪ�ļ��� */
int
logger_init(struct logger * inst, struct skynet_context *ctx, const char * parm) {
	if (parm) {
		inst->handle = fopen(parm,"w");/* open file for write */
		if (inst->handle == NULL) {
			return 1;
		}
		inst->filename = skynet_malloc(strlen(parm)+1);
		strcpy(inst->filename, parm);
		inst->close = 1;
	} else {
		inst->handle = stdout;//���û������logger������ļ�������Ĭ��ʹ�ñ�׼���
	}
	if (inst->handle) {//����logger�������Ϣ������
		skynet_callback(ctx, inst, logger_cb);
		skynet_command(ctx, "REG", ".logger");//ע�������Ϊ.logger
		return 0;
	}
	return 1;
}

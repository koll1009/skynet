#include "skynet.h"
#include "skynet_socket.h"
#include "databuffer.h"
#include "hashid.h"

#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>

#define BACKLOG 32

struct connection {
	int id;	// skynet_socket id
	uint32_t agent;
	uint32_t client;
	char remote_name[32];
	struct databuffer buffer;
};

struct gate {
	struct skynet_context *ctx;
	int listen_id;
	uint32_t watchdog;
	uint32_t broker;
	int client_tag;
	int header_size;
	int max_connection;
	struct hashid hash;
	struct connection *conn;
	// todo: save message pool ptr for release
	struct messagepool mp;
};

//创建gate服务上下文
struct gate *
gate_create(void) {
	struct gate * g = skynet_malloc(sizeof(*g));
	memset(g,0,sizeof(*g));
	g->listen_id = -1;
	return g;
}

void
gate_release(struct gate *g) {
	int i;
	struct skynet_context *ctx = g->ctx;
	for (i=0;i<g->max_connection;i++) {
		struct connection *c = &g->conn[i];
		if (c->id >=0) {
			skynet_socket_close(ctx, c->id);
		}
	}
	if (g->listen_id >= 0) {
		skynet_socket_close(ctx, g->listen_id);
	}
	messagepool_free(&g->mp);
	hashid_clear(&g->hash);
	skynet_free(g->conn);
	skynet_free(g);
}

static void
_parm(char *msg, int sz, int command_sz) {
	while (command_sz < sz) {
		if (msg[command_sz] != ' ')
			break;
		++command_sz;
	}
	int i;
	for (i=command_sz;i<sz;i++) {
		msg[i-command_sz] = msg[i];
	}
	msg[i-command_sz] = '\0';
}

static void
_forward_agent(struct gate * g, int fd, uint32_t agentaddr, uint32_t clientaddr) {
	int id = hashid_lookup(&g->hash, fd);
	if (id >=0) {
		struct connection * agent = &g->conn[id];
		agent->agent = agentaddr;
		agent->client = clientaddr;
	}
}

//gate服务PTYPE_TEXT类消息处理函数
static void
_ctrl(struct gate * g, const void * msg, int sz) {
	struct skynet_context * ctx = g->ctx;
	char tmp[sz+1];
	memcpy(tmp, msg, sz);
	tmp[sz] = '\0';
	char * command = tmp;
	int i;
	if (sz == 0)
		return;
	for (i=0;i<sz;i++) {
		if (command[i]==' ') {//消息内容以空格符分格
			break;
		}
	}
	if (memcmp(command,"kick",i)==0) {
		_parm(tmp, sz, i);
		int uid = strtol(command , NULL, 10);
		int id = hashid_lookup(&g->hash, uid);
		if (id>=0) {
			skynet_socket_close(ctx, uid);
		}
		return;
	}
	if (memcmp(command,"forward",i)==0) {
		_parm(tmp, sz, i);
		char * client = tmp;
		char * idstr = strsep(&client, " ");
		if (client == NULL) {
			return;
		}
		int id = strtol(idstr , NULL, 10);
		char * agent = strsep(&client, " ");
		if (client == NULL) {
			return;
		}
		uint32_t agent_handle = strtoul(agent+1, NULL, 16);
		uint32_t client_handle = strtoul(client+1, NULL, 16);
		_forward_agent(g, id, agent_handle, client_handle);
		return;
	}
	if (memcmp(command,"broker",i)==0) {//broker命令，则后跟服务handle
		_parm(tmp, sz, i);
		g->broker = skynet_queryname(ctx, command);//设置broker服务
		return;
	}
	if (memcmp(command,"start",i) == 0) {//start命令，发送一个start请求
		skynet_socket_start(ctx, g->listen_id);
		return;
	}
    if (memcmp(command, "close", i) == 0) {
		if (g->listen_id >= 0) {
			skynet_socket_close(ctx, g->listen_id);
			g->listen_id = -1;
		}
		return;
	}
	skynet_error(ctx, "[gate] Unkown command : %s", command);
}

static void
_report(struct gate * g, const char * data, ...) {
	if (g->watchdog == 0) {
		return;
	}
	struct skynet_context * ctx = g->ctx;
	va_list ap;
	va_start(ap, data);
	char tmp[1024];
	int n = vsnprintf(tmp, sizeof(tmp), data, ap);
	va_end(ap);

	skynet_send(ctx, 0, g->watchdog, PTYPE_TEXT,  0, tmp, n);
}

//把接收到的数据转发到gate服务对应的其他服务中
static void
_forward(struct gate *g, struct connection * c, int size) {
	struct skynet_context * ctx = g->ctx;
	if (g->broker) {
		void * temp = skynet_malloc(size);
		databuffer_read(&c->buffer,&g->mp,temp, size);//把接收到的数据统一copy到temp中
		skynet_send(ctx, 0, g->broker, g->client_tag | PTYPE_TAG_DONTCOPY, 0, temp, size);//发送到broker服务
		return;
	}
	if (c->agent) {
		void * temp = skynet_malloc(size);
		databuffer_read(&c->buffer,&g->mp,temp, size);
		skynet_send(ctx, c->client, c->agent, g->client_tag | PTYPE_TAG_DONTCOPY, 0 , temp, size);
	} else if (g->watchdog) {
		char * tmp = skynet_malloc(size + 32);
		int n = snprintf(tmp,32,"%d data ",c->id);
		databuffer_read(&c->buffer,&g->mp,tmp+n,size);
		skynet_send(ctx, 0, g->watchdog, PTYPE_TEXT | PTYPE_TAG_DONTCOPY, 0, tmp, size + n);
	}
}

//处理接收到的消息
static void
dispatch_message(struct gate *g, struct connection *c, int id, void * data, int sz) {
	databuffer_push(&c->buffer,&g->mp, data, sz);//压到connection的data buffer中
	for (;;) {
		int size = databuffer_readheader(&c->buffer, &g->mp, g->header_size);//消息内容的总大小
		if (size < 0) {
			return;
		} else if (size > 0) {
			if (size >= 0x1000000) {//超过16m，不做处理
				struct skynet_context * ctx = g->ctx;
				databuffer_clear(&c->buffer,&g->mp);
				skynet_socket_close(ctx, id);
				skynet_error(ctx, "Recv socket message > 16M");
				return;
			} else {
				_forward(g, c, size);
				databuffer_reset(&c->buffer);
			}
		}
	}
}

//PTYPE_SOCKET类消息处理函数
static void
dispatch_socket_message(struct gate *g, const struct skynet_socket_message * message, int sz) {
	struct skynet_context * ctx = g->ctx;
	switch(message->type) {
	case SKYNET_SOCKET_TYPE_DATA: {//接收到的数据
		int id = hashid_lookup(&g->hash, message->id);
		if (id>=0) {
			struct connection *c = &g->conn[id];
			dispatch_message(g, c, message->id, message->buffer, message->ud);
		} else {
			skynet_error(ctx, "Drop unknown connection %d message", message->id);
			skynet_socket_close(ctx, message->id);
			skynet_free(message->buffer);
		}
		break;
	}
	case SKYNET_SOCKET_TYPE_CONNECT: {//start请求的响应消息
		if (message->id == g->listen_id) {//start server sock不做处理
			// start listening
			break;
		}
		//此时为client socket
		int id = hashid_lookup(&g->hash, message->id);
		if (id>=0) {
			struct connection *c = &g->conn[id];
			_report(g, "%d open %d %s:0",message->id,message->id,c->remote_name);//向网关的watchdof服务发送客户端ip
		} else {
			skynet_error(ctx, "Close unknown connection %d", message->id);
			skynet_socket_close(ctx, message->id);
		}
		break;
	}
	case SKYNET_SOCKET_TYPE_CLOSE:
	case SKYNET_SOCKET_TYPE_ERROR: {
		int id = hashid_remove(&g->hash, message->id);
		if (id>=0) {
			struct connection *c = &g->conn[id];
			databuffer_clear(&c->buffer,&g->mp);
			memset(c, 0, sizeof(*c));
			c->id = -1;
			_report(g, "%d close", message->id);
		}
		break;
	}
	case SKYNET_SOCKET_TYPE_ACCEPT://监听到client sock 连接
		// report accept, then it will be get a SKYNET_SOCKET_TYPE_CONNECT message
		assert(g->listen_id == message->id);
		if (hashid_full(&g->hash)) {//最大连接数已用完
			skynet_socket_close(ctx, message->ud);
		} else {
			struct connection *c = &g->conn[hashid_insert(&g->hash, message->ud)];//分配connection对象
			if (sz >= sizeof(c->remote_name)) {
				sz = sizeof(c->remote_name) - 1;
			}
			c->id = message->ud;
			memcpy(c->remote_name, message+1, sz);//保存ip
			c->remote_name[sz] = '\0';
			skynet_socket_start(ctx, message->ud);//启动client sock
		}
		break;
	}
}

static int
_cb(struct skynet_context * ctx, void * ud, int type, int session, uint32_t source, const void * msg, size_t sz) {
	struct gate *g = ud;
	switch(type) {
	case PTYPE_TEXT:
		_ctrl(g , msg , (int)sz);
		break;
	case PTYPE_CLIENT: {
		if (sz <=4 ) {
			skynet_error(ctx, "Invalid client message from %x",source);
			break;
		}
		// The last 4 bytes in msg are the id of socket, write following bytes to it
		const uint8_t * idbuf = msg + sz - 4;
		uint32_t uid = idbuf[0] | idbuf[1] << 8 | idbuf[2] << 16 | idbuf[3] << 24;
		int id = hashid_lookup(&g->hash, uid);
		if (id>=0) {
			// don't send id (last 4 bytes)
			skynet_socket_send(ctx, uid, (void*)msg, sz-4);
			// return 1 means don't free msg
			return 1;
		} else {
			skynet_error(ctx, "Invalid client id %d from %x",(int)uid,source);
			break;
		}
	}
	case PTYPE_SOCKET:
		assert(source == 0);
		// recv socket message from skynet_socket
		dispatch_socket_message(g, msg, (int)(sz-sizeof(struct skynet_socket_message)));
		break;
	}
	return 0;
}

//gate服务开始监听
static int
start_listen(struct gate *g, char * listen_addr) {
	struct skynet_context * ctx = g->ctx;
	char * portstr = strchr(listen_addr,':');//取ip地址、端口号
	const char * host = "";
	int port;
	if (portstr == NULL) {
		port = strtol(listen_addr, NULL, 10);
		if (port <= 0) {
			skynet_error(ctx, "Invalid gate address %s",listen_addr);
			return 1;
		}
	} else {
		port = strtol(portstr + 1, NULL, 10);
		if (port <= 0) {
			skynet_error(ctx, "Invalid gate address %s",listen_addr);
			return 1;
		}
		portstr[0] = '\0';
		host = listen_addr;
	}
	g->listen_id = skynet_socket_listen(ctx, host, port, BACKLOG);//监听操作
	if (g->listen_id < 0) {
		return 1;
	}
	return 0;
}

//初始化gate服务
int
gate_init(struct gate *g , struct skynet_context * ctx, char * parm) {
	if (parm == NULL)
		return 1;
	int max = 0;
	int buffer = 0;
	int sz = strlen(parm)+1;
	char watchdog[sz];
	char binding[sz];
	int client_tag = 0;
	char header;

	//参数由headsize标识字符、watchdog服务名、监听ip地址、消息类型、最大连接数、buffer大小以空格separate组成
	int n = sscanf(parm, "%c %s %s %d %d %d",&header,watchdog, binding,&client_tag , &max,&buffer);
	if (n<4) {
		skynet_error(ctx, "Invalid gate parm %s",parm);
		return 1;
	}
	if (max <=0 ) {
		skynet_error(ctx, "Need max connection");
		return 1;
	}
	if (header != 'S' && header !='L') {
		skynet_error(ctx, "Invalid data header style");
		return 1;
	}

	if (client_tag == 0) {
		client_tag = PTYPE_CLIENT;
	}
	if (watchdog[0] == '!') {
		g->watchdog = 0;
	} else {
		g->watchdog = skynet_queryname(ctx, watchdog);
		if (g->watchdog == 0) {
			skynet_error(ctx, "Invalid watchdog %s",watchdog);
			return 1;
		}
	}

	g->ctx = ctx;

	hashid_init(&g->hash, max);//初始化hashid

    //每个监听到socket，匹配一个hashid_node及connection对象
	g->conn = skynet_malloc(max * sizeof(struct connection));
	memset(g->conn, 0, max *sizeof(struct connection));
	g->max_connection = max;
	int i;
	for (i=0;i<max;i++) {
		g->conn[i].id = -1;
	}
	
	g->client_tag = client_tag;//消息类型标记
	g->header_size = header=='S' ? 2 : 4;//头部大小，存储消息的长度

	skynet_callback(ctx,g,_cb);//设置gate服务的消息处理函数

	return start_listen(g,binding);//开始监听
}

#ifndef skynet_databuffer_h
#define skynet_databuffer_h

#include <stdlib.h>
#include <string.h>
#include <assert.h>

#define MESSAGEPOOL 1023

/* epoll里的网络数据，会以message的形式存储，考虑到数据大分包的可能，所以定义了一个@next指针 */
struct message {
	char * buffer;//网络数据缓存
	int size;//网络数据的长度
	struct message * next;
};

/* 通信中完整数据缓冲区结构体 */
struct databuffer {
	int header;//数据包以size+data的协议格式封装，header用来存储解析后的size的数值
	int offset;//在当前处理的message中的偏移值
	int size;//数据大小
	struct message * head;//数据块的头尾指针
	struct message * tail;
};

/* message pool，会预分配1023个message结构体 */
struct messagepool_list {
	struct messagepool_list *next;
	struct message pool[MESSAGEPOOL];
};

struct messagepool {
	struct messagepool_list * pool;
	struct message * freelist;
};

// use memset init struct 

static void 
messagepool_free(struct messagepool *pool) {
	struct messagepool_list *p = pool->pool;
	while(p) {
		struct messagepool_list *tmp = p;
		p=p->next;
		skynet_free(tmp);
	}
	pool->pool = NULL;
	pool->freelist = NULL;
}

/* databuffer的当前message回收，并且重置为下一个待处理message */
static inline void
_return_message(struct databuffer *db, struct messagepool *mp) {
	struct message *m = db->head;
	if (m->next == NULL) {//重置
		assert(db->tail == m);
		db->head = db->tail = NULL;
	} else {
		db->head = m->next;
	}
	skynet_free(m->buffer);
	m->buffer = NULL;//回收到freelist中
	m->size = 0;
	m->next = mp->freelist;
	mp->freelist = m;
}


/* 从当前databuffer中读取sz个字符存储到buffer中 */
static void
databuffer_read(struct databuffer *db, struct messagepool *mp, void * buffer, int sz) {
	assert(db->size >= sz);
	db->size -= sz;
	for (;;) {
		struct message *current = db->head;
		int bsz = current->size - db->offset;//先计算当前message的数据量，分为三个情况处理
		if (bsz > sz) {//当前message中的数据足够，copy
			memcpy(buffer, current->buffer + db->offset, sz);
			db->offset += sz;
			return;
		}
		if (bsz == sz) {//当前message中的数据正好等于要读取的，copy并且把当前message回收
			memcpy(buffer, current->buffer + db->offset, sz);
			db->offset = 0;
			_return_message(db, mp);
			return;
		} else {//当前message中的数据不足，copy，并且把当前message回收，并计算欠缺的数值，循环处理
			memcpy(buffer, current->buffer + db->offset, bsz);
			_return_message(db, mp);
			db->offset = 0;
			buffer+=bsz;
			sz-=bsz;
		}
	}
}


/* 往databuffer中添加一个数据块 */
static void
databuffer_push(struct databuffer *db, struct messagepool *mp, void *data, int sz) {
	struct message * m;
	if (mp->freelist) {//先取空闲的message
		m = mp->freelist;
		mp->freelist = m->next;
	} else {
		struct messagepool_list * mpl = skynet_malloc(sizeof(*mpl));//重新分配一个message pool，每个pool会预分配1023个message结构体
		struct message * temp = mpl->pool;
		int i;
		for (i=1;i<MESSAGEPOOL;i++) {//把message数组以链表的形式链接起来
			temp[i].buffer = NULL;
			temp[i].size = 0;
			temp[i].next = &temp[i+1];
		}
		temp[MESSAGEPOOL-1].next = NULL;
		mpl->next = mp->pool;
		mp->pool = mpl;
		m = &temp[0];
		mp->freelist = &temp[1];
	}
	m->buffer = data;
	m->size = sz;
	m->next = NULL;
	db->size += sz;
	if (db->head == NULL) {
		assert(db->tail == NULL);
		db->head = db->tail = m;
	} else {
		db->tail->next = m;
		db->tail = m;
	}
}

/* 解析databuffer中的数据，每个tcp数据包是以size+data的协议格式封装的 */
static int
databuffer_readheader(struct databuffer *db, struct messagepool *mp, int header_size) {
	if (db->header == 0) {//先解析数据包的长度
		// parser header (2 or 4)
		if (db->size < header_size) {
			return -1;
		}
		uint8_t plen[4];
		databuffer_read(db,mp,(char *)plen,header_size);
		// big-endian
		if (header_size == 2) {
			db->header = plen[0] << 8 | plen[1];
		} else {
			db->header = plen[0] << 24 | plen[1] << 16 | plen[2] << 8 | plen[3];
		}
	}
	if (db->size < db->header)
		return -1;
	return db->header;
}

static inline void
databuffer_reset(struct databuffer *db) {
	db->header = 0;
}

static void
databuffer_clear(struct databuffer *db, struct messagepool *mp) {
	while (db->head) {
		_return_message(db,mp);
	}
	memset(db, 0, sizeof(*db));
}

#endif

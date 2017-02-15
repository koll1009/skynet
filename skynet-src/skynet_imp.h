#ifndef SKYNET_IMP_H
#define SKYNET_IMP_H

/* 配置信息 */
struct skynet_config {
	int thread;/* 线程数 */
	int harbor;
	const char * daemon;
	const char * module_path;/* 库路径 */
	const char * bootstrap;  /* 引导程序 */
	const char * logger;
	const char * logservice;
};

#define THREAD_WORKER 0
#define THREAD_MAIN 1
#define THREAD_SOCKET 2
#define THREAD_TIMER 3
#define THREAD_MONITOR 4

void skynet_start(struct skynet_config * config);

#endif

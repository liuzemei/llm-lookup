// 三指轻点检测：独立进程直接读触控板原始触点（MultitouchSupport 私有框架），
// 只旁观、不拦截任何输入事件，所以不会拖慢拖动和滚动。
// 输出到 stdout，一行一个事件：
//   ready <设备数>   启动完成
//   down             三根手指刚落下（Hammerspoon 趁这时记下选区）
//   tap              完成一次三指轻点
//
// 编译：clang -O2 -o bin/tapwatch tapwatch.c -framework CoreFoundation

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
  int frame;
  double timestamp;
  int identifier;
  int state; // 3 = 刚接触，4 = 接触中
  int fingerId;
  int handId;
  MTVector normalized; // 0..1，左下角为原点
  float size;
  int zero1;
  float angle, majorAxis, minorAxis;
  MTVector absolute;
  int zero2, zero3;
  float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTFrameCallback)(MTDeviceRef, const MTTouch *, int, double, int);

#define LAND_SECONDS 0.12 // 三根手指必须在这么短时间内先后落下
#define MAX_SECONDS 0.30  // 从第一根手指落下到全部抬起
#define MAX_MOVE 0.02     // 归一化坐标
#define COOLDOWN 0.80
#define GAP_RESET 0.25    // 两帧间隔太久，说明上一次触摸早结束了

#define MAX_DEVICES 8
#define MAX_IDS 16

typedef struct {
  MTDeviceRef dev;
  int active, max, prev, invalid, nids;
  double t0, last;
  int ids[MAX_IDS];
  float sx[MAX_IDS], sy[MAX_IDS];
} Session;

static Session sessions[MAX_DEVICES];
static double lastTap = 0;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void emit(const char *what) {
  fputs(what, stdout);
  fputc('\n', stdout);
  fflush(stdout);
}

static Session *sessionFor(MTDeviceRef dev) {
  for (int i = 0; i < MAX_DEVICES; i++)
    if (sessions[i].dev == dev) return &sessions[i];
  for (int i = 0; i < MAX_DEVICES; i++)
    if (!sessions[i].dev) {
      sessions[i].dev = dev;
      return &sessions[i];
    }
  return &sessions[0];
}

static void track(Session *s, const MTTouch *t) {
  for (int i = 0; i < s->nids; i++) {
    if (s->ids[i] == t->identifier) {
      float d = fabsf(t->normalized.position.x - s->sx[i]) + fabsf(t->normalized.position.y - s->sy[i]);
      if (d > MAX_MOVE) s->invalid = 1;
      return;
    }
  }
  if (s->nids < MAX_IDS) {
    s->ids[s->nids] = t->identifier;
    s->sx[s->nids] = t->normalized.position.x;
    s->sy[s->nids] = t->normalized.position.y;
    s->nids++;
  }
}

static int onFrame(MTDeviceRef dev, const MTTouch *touches, int count, double ts, int frame) {
  (void)frame;
  pthread_mutex_lock(&lock);
  Session *s = sessionFor(dev);

  int n = 0;
  for (int i = 0; i < count; i++)
    if (touches[i].state == 3 || touches[i].state == 4) n++;

  if (s->active && ts - s->last > GAP_RESET) s->active = 0;
  s->last = ts;

  if (!s->active && n > 0) {
    s->active = 1;
    s->t0 = ts;
    s->max = s->prev = s->invalid = s->nids = 0;
  }

  if (s->active) {
    if (!s->invalid) {
      // 超过 3 指、手指抬起后又落下、落指太慢、按太久、有移动，都不算轻点
      if (n > 3 || (n > s->prev && s->prev < s->max) || (n == 3 && s->max < 3 && ts - s->t0 > LAND_SECONDS) ||
          ts - s->t0 > MAX_SECONDS) {
        s->invalid = 1;
      } else {
        for (int i = 0; i < count; i++)
          if (touches[i].state == 3 || touches[i].state == 4) track(s, &touches[i]);
      }
    }
    if (n > s->max) {
      s->max = n;
      // 第二、第三根手指落下时都通知，让 Hammerspoon 尽早记下选区：
      // 开着「三指拖移」时系统可能一碰到就发鼠标按下，终端、编辑器会立刻清掉选区
      if ((n == 2 || n == 3) && !s->invalid) emit("down");
    }
    s->prev = n;
    if (n == 0) {
      if (s->max == 3 && !s->invalid && ts - lastTap > COOLDOWN) {
        lastTap = ts;
        emit("tap");
      }
      s->active = 0;
    }
  }

  pthread_mutex_unlock(&lock);
  return 0;
}

// Hammerspoon 退出或重载后父进程会变，跟着退出，不留孤儿进程
static void *watchParent(void *arg) {
  pid_t parent = *(pid_t *)arg;
  for (;;) {
    sleep(2);
    if (getppid() != parent) exit(0);
  }
  return NULL;
}

int main(void) {
  void *mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
  CFArrayRef (*createList)(void) = mt ? dlsym(mt, "MTDeviceCreateList") : NULL;
  void (*registerCallback)(MTDeviceRef, MTFrameCallback) = mt ? dlsym(mt, "MTRegisterContactFrameCallback") : NULL;
  void (*start)(MTDeviceRef, int) = mt ? dlsym(mt, "MTDeviceStart") : NULL;
  if (!createList || !registerCallback || !start) {
    fprintf(stderr, "MultitouchSupport unavailable\n");
    return 1;
  }

  CFArrayRef devices = createList();
  CFIndex n = devices ? CFArrayGetCount(devices) : 0;
  for (CFIndex i = 0; i < n; i++) {
    MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
    registerCallback(d, onFrame);
    start(d, 0);
  }

  static pid_t parent;
  parent = getppid();
  pthread_t t;
  pthread_create(&t, NULL, watchParent, &parent);

  printf("ready %ld\n", (long)n);
  fflush(stdout);
  CFRunLoopRun();
  return 0;
}

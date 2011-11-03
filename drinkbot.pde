#include <Servo.h>
#include <Max3421e.h>
#include <Usb.h>
#include <AndroidAccessory.h>

void handle_request(android_request_t *request);

#define USE_ANDROID 1

#ifdef USE_ANDROID
AndroidAccessory acc("Google, Inc.",
                     "iZac",
                     "A robot that makes drinks for you",
                     "0.1",
                     "http://www.android.com/",
                     "ec4a9267-0b5a-43e2-a52d-7d7b46c0c02c");
#endif

const int slew_delay = 50;
const int scale_divisor = 515;

typedef struct {
  int turntable_pin;
  int pump_pin;
  int position;
  Servo servo;
} turntable_t;

turntable_t turntables[] = {
  //turntable_pin, pump_pin, position
  { 10,            8,        150},
  NULL
};

typedef struct {
  int turntable_num;
  int turntable_pos;
  int valve_pin;
  int valve_open_pos;
  int valve_close_pos;
  Servo valve;
} dispenser_t;

dispenser_t dispensers[] = {
  //turntable_num, turntable_pos, valve_pin, valve_open_pos, valve_close_pos
  {0,              178,            12,       170,            75},
  {0,              150,            9,        170,            76},
  {0,              121,            11,       170,            90},
  NULL
};

typedef struct android_request_t {
  uint8_t command;
  uint8_t target;
  int16_t value;
} android_request_t;

typedef struct android_response_t {
  uint8_t status;
  int16_t progress;
} android_response_t;

int num_dispensers = 0; // Initialized in init()

void setup_turntables() {
  for(turntable_t *t = turntables; t->turntable_pin != 0; t++) {
    Serial.print("Attaching turntable on pin ");
    Serial.print(t->turntable_pin);
    Serial.println(".");
    t->servo.attach(t->turntable_pin);
    t->servo.write(t->position);
    Serial.print("Enabling pump on pin ");
    Serial.print(t->pump_pin);
    Serial.println(".");
    digitalWrite(t->pump_pin, LOW);
    pinMode(t->pump_pin, OUTPUT);
  }
  for(dispenser_t *d = dispensers; d->valve_pin != 0; d++) {
    Serial.print("Attaching valve on pin ");
    Serial.print(d->valve_pin);
    Serial.println(".");
    d->valve.attach(d->valve_pin);
    d->valve.write(d->valve_close_pos - 10);
    num_dispensers++;
  }
  delay(200);
  for(dispenser_t *d = dispensers; d->valve_pin != 0; d++)
    d->valve.write(d->valve_close_pos);
}

void setup() {
  Serial.begin(19200);
  setup_turntables();
  Serial.println("Ready.");
#ifdef USE_ANDROID
  acc.powerOn();
#endif
}

void read_line(char *buf, char terminator) {
  char *bufptr = buf;
  for(;;) {
    if(Serial.available() > 0) {
      *bufptr = (char)Serial.read();
      if(*bufptr == terminator) {
        *bufptr = '\0';
        return;
      } else {
        bufptr++;
      }
    }
  }
}

void send_response(struct android_response_t *msg) {
  Serial.print("  status=");
  Serial.print((int)msg->status);
  Serial.print(", progress=");
  Serial.print((int)msg->progress);
  Serial.println();
#ifdef USE_ANDROID
  int ret = acc.write(msg, sizeof(android_response_t));
  Serial.print("Write returned status ");
  Serial.println(ret, HEX);
#endif
}

uint32_t read_scale() {
  uint32_t total = 0;
  for(int i = 0; i < 1024; i++)
    total += analogRead(A0);
  total >>= 5;
  return total;
}

void do_valve(int dispenser_num, int val) {
  Serial.print("Valve ");
  Serial.print(dispenser_num);
  Serial.print(" to ");
  Serial.println(val);
  dispensers[dispenser_num].valve.write(val);
}

void do_turn(int turntable_num, int val) {
  Serial.print("Turn turntable ");
  Serial.print(turntable_num);
  Serial.print( " to ");
  Serial.println(val);
  
  turntable_t *turntable = &turntables[turntable_num];
  
  if(val > turntable->position) {
    for(int i = turntable->position + 1; i <= val; i++) {
      turntable->servo.write(i);
      delay(slew_delay);
    }
  } else {
    for(int i = turntable->position - 1; i >= val; i--) {
      turntable->servo.write(i);
      delay(slew_delay);
    }
  }
  
  turntable->position = val;
}

void do_pump(int target, int val) {
  Serial.print("Pump to ");
  Serial.println(val);
  digitalWrite(turntables[target].pump_pin, val);
}

void wait_command() {
  Serial.println("Waiting for glass.");
  int32_t target_value = read_scale() + scale_divisor / 10;
  while(read_scale() < target_value);
  Serial.println("Detected glass on scale.");
  
  android_response_t response = {20, 0};
  send_response(&response);
}

void dispense_command(int target, int amount) {
  if(target > num_dispensers) {
    android_response_t response = {40, 0};
    send_response(&response);
    return;
  }
  
  Serial.print("Dispensing ");
  Serial.print(amount);
  Serial.print("ml from dispenser number");
  Serial.println(target);

  dispenser_t *dispenser = &dispensers[target];
  do_pump(dispenser->turntable_num, HIGH);
  do_turn(dispenser->turntable_num, dispenser->turntable_pos);
  delay(2000);
  do_valve(target, dispenser->valve_open_pos);
  
  int32_t scale_zero = read_scale();
  int32_t final_value = scale_zero + (scale_divisor * (int32_t)amount) / 10;
  int32_t current_value;
  int last_progress = 0;
  while((current_value = read_scale()) < final_value) {
    current_value = ((current_value - scale_zero) * 10) / scale_divisor;
    if(last_progress < current_value) {
      last_progress = current_value;
      Serial.print(current_value);
      Serial.println(" grams dispensed.");
      android_response_t response = {10, current_value};
      send_response(&response);
    }
  }
  
  do_pump(dispenser->turntable_num, LOW);
  do_valve(target, dispenser->valve_close_pos - 10);
  delay(200);
  do_valve(target, dispenser->valve_close_pos);
  
  android_response_t response = {20, amount};
  send_response(&response);
}

void handle_request(struct android_request_t *request) {
  Serial.print("Command: ");
  Serial.print((char)request->command);
  Serial.print(" (0x");
  Serial.print(request->command, HEX);
  Serial.print("), target =");
  Serial.print((int)request->target);
  Serial.print(", value =");
  Serial.println(request->value);

  switch(request->command) {
  case 'w':
    wait_command();
    break;
  case 'd':
    dispense_command(request->target, request->value);
    break;
  case 't':
    do_turn(request->target, request->value);
    break;
  case 'p':
    do_pump(request->target, request->value);
    break;
  case 'v':
    do_valve(request->target, request->value);
    break;
  }
}

#ifdef USE_ANDROID
void handle_android_request() {
  android_request_t request;
  char *buf_ptr = (char *)&request;
  int total_len = 0;
  if(acc.isConnected()) {
    Serial.println("Waiting for command from Android.");
    while(total_len < sizeof(request)) {
      int len = acc.read(buf_ptr + total_len, sizeof(request) - total_len, 1);
      if(len > 0)
        total_len += len;
    }
    handle_request(&request);
  }
}
#endif

void handle_serial_request() {
  char buf[32];
  android_request_t request;

  read_line(buf, '\n');
  sscanf(buf, "%c %hhd %hd", &request.command, &request.target, &request.value);
  handle_request(&request);
}

void loop() {
#ifdef USE_ANDROID
  handle_android_request();
#else
  handle_serial_request();
#endif
}


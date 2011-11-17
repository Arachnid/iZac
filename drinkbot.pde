#include <Servo.h>
#include <Max3421e.h>
#include <Usb.h>
#include <AndroidAccessory.h>

void handle_request(android_request_t *request);

AndroidAccessory acc("Google, Inc.",
                     "iZac",
                     "A robot that makes drinks for you",
                     "0.1",
                     "http://www.android.com/",
                     "ec4a9267-0b5a-43e2-a52d-7d7b46c0c02c");

const int slew_delay = 50;
const int scale_divisor = 501;

typedef struct {
  int turntable_pin;
  int pump_pin;
  int position;
  int rest_position;
  Servo servo;
} turntable_t;

turntable_t turntables[] = {
  //turntable_pin, pump_pin, position, rest_position
  { 10,            8,        165,      165},
  { 5,             3,        165,      165},
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
  {0,              122,            11,       170,            90},
  {1,              178,            7,        160,            82},
  {1,              145,            4,        170,            85},
  {1,              114,            6,        170,            91},
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
int last_turntable = 0; // Last turntable used to mix a drink

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
  acc.powerOn();
  analogReference(EXTERNAL);
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

  int ret = acc.write(msg, sizeof(android_response_t));
  Serial.print("Write returned status ");
  Serial.println(ret, HEX);
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
  if(target >= num_dispensers) {
    android_response_t response = {40, 0};
    send_response(&response);
    return;
  }
  
  Serial.print("Dispensing ");
  Serial.print(amount);
  Serial.print("ml from dispenser number");
  Serial.println(target);

  dispenser_t *dispenser = &dispensers[target];
  
  // Get the other turntable out of the way
  if(dispenser->turntable_num != last_turntable) {
    do_turn(last_turntable,
            turntables[last_turntable].rest_position);
    last_turntable = dispenser->turntable_num;
  }
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

void do_read_scale() {
  int32_t value = read_scale();
  int32_t grams = (value * 10) / scale_divisor;
  Serial.print("Scale reads ");
  Serial.print(grams);
  Serial.print(" grams (");
  Serial.print(value);
  Serial.println(").");
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
  case 's':
    do_read_scale();
    break;
  }
}

void android_read() {
  android_request_t request;
  
  if(acc.isConnected()) {
    int len = acc.read(&request, sizeof(request), 1);
    if(len == sizeof(request)) {
      handle_request(&request);
    }
  }
}

void serial_read() {
  static char buf[32];
  static char pos = 0;
  
  while(Serial.available()) {
    int cur = Serial.read();
    if(cur < 0)
      return;
    if(cur == '\n') {
      android_request_t request;
      buf[pos] = '\0';
      sscanf(buf, "%c %hhd %hd",
             &request.command, &request.target, &request.value);
      handle_request(&request);
      pos = 0;
    } else {
      buf[pos++] = cur;
    }
  }
}

void loop() {
  android_read();
  serial_read();
}


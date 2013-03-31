
#include "mouse.h"
#include "debug.h"
#include <sys/time.h>
#include <pthread.h>
#include <IOKit/hidsystem/event_status_driver.h>
#include <IOKit/hidsystem/IOHIDShared.h>

#include <list>

#include "prio.h"
#include "driver.h"
#include "debug.h"

extern Driver driver;
extern BOOL is_debug;

static CGEventSourceRef eventSource = NULL;
io_connect_t iohid_connect = MACH_PORT_NULL;
pthread_t driverEventThreadID;

pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t data_available = PTHREAD_COND_INITIALIZER;

std::list<driver_event_t> event_list;
BOOL keep_running;

static void *HandleDriverEventThread(void *instance);
static BOOL driver_handle_button_event(driver_button_event_t *event);
static BOOL driver_handle_move_event(driver_move_event_t *event);

BOOL driver_post_event(driver_event_t *event) {
    pthread_mutex_lock(&mutex);
    if (event->id == DRIVER_EVENT_ID_MOVE && event_list.size() > 0) {
        // see if it's possible to merge two events
        driver_event_t back = event_list.back();
        if (back.move.type == event->move.type &&
            back.move.buttons == event->move.buttons &&
            back.move.otherButton == event->move.otherButton) {
            back.move.pos = event->move.pos;
            back.move.deltaX += event->move.deltaX;
            back.move.deltaY += event->move.deltaY;
            event_list.pop_back();
            event_list.push_back(back);
            //LOG(@"2 move events merged");
        } else {
/*            NSLog(@"Wrong kind of event, id: %d, type: %d %d, buttons: %d %d, other: %d %d",
                  back.id,
                  back.move.type,
                  event->move.type,
                  back.move.buttons,
                  event->move.buttons,
                  back.move.otherButton,
                  event->move.otherButton); */
        }
    } else {
        event_list.push_back(*event);
    }
    pthread_cond_signal(&data_available);
    pthread_mutex_unlock(&mutex);
    return YES;
}

const char *driver_quartz_event_type_to_string(CGEventType type) {
    switch(type) {
        case kCGEventNull:              return "kCGEventNull";
        case kCGEventLeftMouseUp:       return "kCGEventLeftMouseUp";
        case kCGEventLeftMouseDown:     return "kCGEventLeftMouseDown";
        case kCGEventLeftMouseDragged:  return "kCGEventLeftMouseDragged";
        case kCGEventRightMouseUp:      return "kCGEventRightMouseUp";
        case kCGEventRightMouseDown:    return "kCGEventRightMouseDown";
        case kCGEventRightMouseDragged: return "kCGEventRightMouseDragged";
        case kCGEventOtherMouseUp:      return "kCGEventOtherMouseUp";
        case kCGEventOtherMouseDown:    return "kCGEventOtherMouseDown";
        case kCGEventOtherMouseDragged: return "kCGEventOtherMouseDragged";
        case kCGEventMouseMoved:        return "kCGEventMouseMoved";
        default:                        return "?";
    }
}

const char *driver_iohid_event_type_to_string(int type) {
    switch(type) {
        case NX_NULLEVENT:      return "NX_NULLEVENT";
        case NX_LMOUSEUP:       return "NX_LMOUSEUP";
        case NX_LMOUSEDOWN:     return "NX_LMOUSEDOWN";
        case NX_LMOUSEDRAGGED:  return "NX_LMOUSEDRAGGED";
        case NX_RMOUSEUP:       return "NX_RMOUSEUP";
        case NX_RMOUSEDOWN:     return "NX_RMOUSEDOWN";
        case NX_RMOUSEDRAGGED:  return "NX_RMOUSEDRAGGED";
        case NX_OMOUSEUP:       return "NX_OMOUSEUP";
        case NX_OMOUSEDOWN:     return "NX_OMOUSEDOWN";
        case NX_OMOUSEDRAGGED:  return "NX_OMOUSEDRAGGED";
        case NX_MOUSEMOVED:     return "NX_MOUSEMOVED";
        default:                return "?";
    }
}

static void *HandleDriverEventThread(void *instance)
{
    prio_set_realtime();

    LOG(@"HandleDriverEventThread started");

    while(keep_running) {
        driver_event_t event;
        pthread_mutex_lock(&mutex);
        while(event_list.empty()) {
            pthread_cond_wait(&data_available, &mutex);
        }
        event = event_list.front();
        event_list.pop_front();
        pthread_mutex_unlock(&mutex);
        switch(event.id) {
            case DRIVER_EVENT_ID_MOVE:
                //LOG(@"DRIVER_EVENT_ID_MOVE");
                driver_handle_move_event((driver_move_event_t *)&(event.move));
                break;
            case DRIVER_EVENT_ID_BUTTON:
                //LOG(@"DRIVER_EVENT_ID_BUTTON");
                driver_handle_button_event((driver_button_event_t *)&(event.button));
                break;
            case DRIVER_EVENT_ID_TERMINATE:
                //LOG(@"DRIVER_EVENT_ID_TERMINATE");
                break;
        }
    }

    LOG(@"HandleDriverEventThread ended");

    return NULL;
}

BOOL driver_init() {
    switch (driver) {
        case DRIVER_QUARTZ_OLD:
        {
            if (CGSetLocalEventsFilterDuringSuppressionState(kCGEventFilterMaskPermitAllEvents,
                                                             kCGEventSuppressionStateRemoteMouseDrag)) {
                NSLog(@"call to CGSetLocalEventsFilterDuringSuppressionState failed");
                /* whatever, but don't continue with interval */
                break;
            }

            if (CGSetLocalEventsSuppressionInterval(0.0)) {
                NSLog(@"call to CGSetLocalEventsSuppressionInterval failed");
                /* ignore */
            }
            break;
        }
        case DRIVER_QUARTZ:
        {
            eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
            if (eventSource == NULL) {
                NSLog(@"call to CGEventSourceSetKeyboardType failed");
                return NO;
            }
            break;
        }
        case DRIVER_IOHID:
        {
            io_connect_t service_connect = IO_OBJECT_NULL;
            io_service_t service;

            service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching(kIOHIDSystemClass));
            if (!service) {
                NSLog(@"call to IOServiceGetMatchingService failed");
                return NO;
            }

            kern_return_t kern_ret = IOServiceOpen(service, mach_task_self(), kIOHIDParamConnectType, &service_connect);
            if (kern_ret != KERN_SUCCESS) {
                NSLog(@"call to IOServiceOpen failed");
                return NO;
            }

            IOObjectRelease(service);

            iohid_connect = service_connect;
            
            break;
        }
    }

    keep_running = YES;

    int threadError = pthread_create(&driverEventThreadID, NULL, &HandleDriverEventThread, NULL);
    if (threadError != 0)
    {
        NSLog(@"Failed to start driver event thread");
        return NO;
    }

    return YES;
}

BOOL driver_cleanup() {

    keep_running = NO;

    driver_event_t terminate_event;
    terminate_event.id = DRIVER_EVENT_ID_TERMINATE;
    driver_post_event(&terminate_event);

    switch (driver) {
        case DRIVER_QUARTZ_OLD:
            break;
        case DRIVER_QUARTZ:
        {
            CFRelease(eventSource);
            eventSource = NULL;
            break;
        }
        case DRIVER_IOHID:
        {
            if (iohid_connect != MACH_PORT_NULL) {
                (void) IOServiceClose(iohid_connect);
            }
            iohid_connect = MACH_PORT_NULL;
            break;
        }
    }

    NSLog(@"Waiting for driver event thread to terminate");
    int rv = pthread_join(driverEventThreadID, NULL);
    if (rv != 0) {
        NSLog(@"Failed to wait for mouse event thread");
    }

    return YES;
}

BOOL driver_handle_move_event(driver_move_event_t *event) {
    int driver_to_use = driver;

    if (driver == DRIVER_IOHID && event->type == kCGEventOtherMouseDragged) {
        driver_to_use = DRIVER_QUARTZ;
    }

    e1 = GET_TIME();
    switch (driver_to_use) {
        case DRIVER_QUARTZ_OLD:
        {
            if (kCGErrorSuccess != CGPostMouseEvent(event->pos, true, 1, BUTTON_DOWN(event->buttons, LEFT_BUTTON))) {
                NSLog(@"Failed to post mouse event");
                exit(0);
            }
            break;
        }
        case DRIVER_QUARTZ:
        {
            CGEventRef evt = CGEventCreateMouseEvent(eventSource, event->type, event->pos, event->otherButton);
            CGEventSetIntegerValueField(evt, kCGMouseEventDeltaX, event->deltaX);
            CGEventSetIntegerValueField(evt, kCGMouseEventDeltaY, event->deltaY);
            CGEventPost(kCGSessionEventTap, evt);
            CFRelease(evt);
            break;
        }
        case DRIVER_IOHID:
        {
            int iohidEventType;

            switch (event->type) {
                case kCGEventMouseMoved:
                    iohidEventType = NX_MOUSEMOVED;
                    break;
                case kCGEventLeftMouseDragged:
                    iohidEventType = NX_LMOUSEDRAGGED;
                    break;
                case kCGEventRightMouseDragged:
                    iohidEventType = NX_RMOUSEDRAGGED;
                    break;
                case kCGEventOtherMouseDragged:
                    iohidEventType = NX_OMOUSEDRAGGED;
                    break;
                default:
                    NSLog(@"INTERNAL ERROR: unknown eventType: %d", event->type);
                    exit(0);
            }

            NXEventData eventData;

            IOGPoint newPoint = { (SInt16) event->pos.x, (SInt16) event->pos.y};

            bzero(&eventData, sizeof(NXEventData));
            eventData.mouseMove.dx = (SInt32)(event->deltaX);
            eventData.mouseMove.dy = (SInt32)(event->deltaY);

            IOOptionBits options;
            if (iohidEventType == NX_MOUSEMOVED) {
                options = kIOHIDSetRelativeCursorPosition;
            } else {
                options = kIOHIDSetCursorPosition;
            }

            (void)IOHIDPostEvent(iohid_connect,
                                 iohidEventType,
                                 newPoint,
                                 &eventData,
                                 kNXEventDataVersion,
                                 0,
                                 options);

            if (is_debug) {
                LOG(@"eventType: %s(%d), newPoint.x: %d, newPoint.y: %d, dx: %d, dy: %d",
                    driver_iohid_event_type_to_string(iohidEventType),
                    (int)iohidEventType,
                    (int)newPoint.x,
                    (int)newPoint.y,
                    (int)eventData.mouseMove.dx,
                    (int)eventData.mouseMove.dy);
            }

            break;
        }
        default:
        {
            NSLog(@"Driver %d not implemented: ", driver);
            exit(0);
        }
    }
    
    e2 = GET_TIME();

    return YES;
}

BOOL driver_handle_button_event(driver_button_event_t *event) {
    int driver_to_use = driver;

    // NOTE: can't get middle mouse to work in iohid, so let's channel all "other" events
    //       through quartz
    if (driver == DRIVER_IOHID &&
        (event->type == kCGEventOtherMouseDown || event->type == kCGEventOtherMouseUp)) {
        driver_to_use = DRIVER_QUARTZ;
    }

    int clickStateValue;
    switch(event->type) {
        case kCGEventLeftMouseDown:
        case kCGEventLeftMouseUp:
            clickStateValue = event->nclicks;
            break;
        case kCGEventRightMouseDown:
        case kCGEventOtherMouseDown:
        case kCGEventRightMouseUp:
        case kCGEventOtherMouseUp:
            clickStateValue = 1;
            break;
        default:
            NSLog(@"INTERNAL ERROR: illegal eventType: %d", event->type);
            exit(0);
    }

    e1 = GET_TIME();
    switch (driver_to_use) {
        case DRIVER_QUARTZ_OLD:
        {
            if (kCGErrorSuccess != CGPostMouseEvent(event->pos, true, 1, BUTTON_DOWN(event->buttons, LEFT_BUTTON))) {
                NSLog(@"Failed to post mouse event");
                exit(0);
            }
            break;
        }
        case DRIVER_QUARTZ:
        {
            CGEventRef evt = CGEventCreateMouseEvent(eventSource, event->type, event->pos, event->otherButton);
            CGEventSetIntegerValueField(evt, kCGMouseEventClickState, clickStateValue);
            CGEventPost(kCGSessionEventTap, evt);
            CFRelease(evt);
            break;
        }
        case DRIVER_IOHID:
        {
            int iohidEventType;
            int is_down_event = 1;

            switch(event->type) {
                case kCGEventLeftMouseDown:
                    iohidEventType = NX_LMOUSEDOWN;
                    break;
                case kCGEventLeftMouseUp:
                    iohidEventType = NX_LMOUSEUP;
                    is_down_event = 0;
                    break;
                case kCGEventRightMouseDown:
                    iohidEventType = NX_RMOUSEDOWN;
                    break;
                case kCGEventRightMouseUp:
                    iohidEventType = NX_RMOUSEUP;
                    is_down_event = 0;
                    break;
                case kCGEventOtherMouseDown:
                    iohidEventType = NX_OMOUSEDOWN;
                    break;
                case kCGEventOtherMouseUp:
                    iohidEventType = NX_OMOUSEUP;
                    is_down_event = 0;
                    break;
                default:
                    NSLog(@"INTERNAL ERROR: unknown eventType: %d", event->type);
                    exit(0);
            }

            // on clicks, refresh own mouse position
            mouse_refresh();

            IOGPoint newPoint = { (SInt16) event->pos.x, (SInt16) event->pos.y };

            NXEventData eventData;
            bzero(&eventData, sizeof(NXEventData));
            eventData.compound.misc.L[0] = 1;
            eventData.compound.misc.L[1] = is_down_event;
            eventData.compound.subType = NX_SUBTYPE_AUX_MOUSE_BUTTONS;

            kern_return_t result = IOHIDPostEvent(iohid_connect, NX_SYSDEFINED, newPoint, &eventData, kNXEventDataVersion, 0, 0);

            if (result != KERN_SUCCESS) {
                NSLog(@"failed to post aux button event");
            }

            static int eventNumber = 0;
            if (is_down_event) eventNumber++;

            bzero(&eventData, sizeof(NXEventData));
            eventData.mouse.click = is_down_event ? clickStateValue : 0;
            eventData.mouse.pressure = is_down_event ? 255 : 0;
            eventData.mouse.eventNum = eventNumber;
            eventData.mouse.buttonNumber = event->otherButton;
            eventData.mouse.subType = NX_SUBTYPE_DEFAULT;

            if (is_debug) {
                LOG(@"eventType: %s(%d), pos: %dx%d, subt: %d, click: %d, pressure: %d, eventNumber: %d, buttonNumber: %d",
                    driver_iohid_event_type_to_string(iohidEventType),
                    (int)iohidEventType,
                    (int)newPoint.x,
                    (int)newPoint.y,
                    (int)eventData.mouse.subType,
                    (int)eventData.mouse.click,
                    (int)eventData.mouse.pressure,
                    (int)eventData.mouse.eventNum,
                    (int)eventData.mouse.buttonNumber);
            }

            result = IOHIDPostEvent(iohid_connect,
                                    iohidEventType,
                                    newPoint,
                                    &eventData,
                                    kNXEventDataVersion,
                                    0,
                                    0);

            if (result != KERN_SUCCESS) {
                NSLog(@"failed to post button event");
            }

            break;
        }
        default:
        {
            NSLog(@"Driver %d not implemented: ", driver);
            exit(0);
        }
    }
    
    e2 = GET_TIME();

    return YES;
}

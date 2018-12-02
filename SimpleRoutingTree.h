#ifndef SIMPLEROUTINGTREE_H
#define SIMPLEROUTINGTREE_H


enum{
	SENDER_QUEUE_SIZE=5,
	RECEIVER_QUEUE_SIZE=3,
	AM_SIMPLEROUTINGTREEMSG=22,
	AM_ROUTINGMSG=22,
	AM_MEASMSG=12,						// AM for MeasMsg
	TIMER_PERIOD_MILLI=60 * 1024,		// Epoch time
	TIMER_FAST_PERIOD=256,				// Send time
	BOOT_TIME = 10 * 1024,				// Time given in simulation to boot
	TIMER_ROUTING_DURATION=3 * 1024,	// Routing Time
	MAX_CHILDREN = 32,					// Maximum number of node's children
};

// Struct for RoutingMsg
typedef nx_struct RoutingMsg
{
	nx_uint16_t senderID;
	nx_uint8_t depth;
} RoutingMsg;

// Struct for ChildInfo
typedef struct ChildInfo
{
    nx_uint16_t childID;
    nx_uint16_t sum;
    nx_uint8_t count;
    nx_uint8_t max;
} ChildInfo;

// Struct for MeasMsg
typedef nx_struct MeasMsg 
{
        nx_uint16_t sum;
        nx_uint8_t count;
        nx_uint8_t max;
}
MeasMsg;

#endif

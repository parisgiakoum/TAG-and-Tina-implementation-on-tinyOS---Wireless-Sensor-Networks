#ifndef SIMPLEROUTINGTREE_H
#define SIMPLEROUTINGTREE_H


enum{
	SENDER_QUEUE_SIZE=5,
	RECEIVER_QUEUE_SIZE=3,
	AM_SIMPLEROUTINGTREEMSG=22,
	AM_ROUTINGMSG=22,
	AM_NOTIFYPARENTMSG=12,
	TIMER_PERIOD_MILLI=60 * 1024,
	TIMER_FAST_PERIOD=200,
	TIMER_ROUTING_DURATION=3 * 1024,
	MAX_DEPTH = 15,
};
/*uint16_t AM_ROUTINGMSG=AM_SIMPLEROUTINGTREEMSG;
uint16_t AM_NOTIFYPARENTMSG=AM_SIMPLEROUTINGTREEMSG;
*/
typedef nx_struct RoutingMsg
{
	nx_uint16_t senderID;
	nx_uint8_t depth;
} RoutingMsg;

typedef struct ChildValues
{
    nx_uint16_t senderID;
    nx_uint16_t sum;
    nx_uint8_t count;
    nx_uint16_t max;
} ChildValues;

typedef nx_struct MeasMsg 
{
        nx_uint16_t sum;
        nx_uint8_t count;
        nx_uint16_t max;
}
MeasMsg;

#endif

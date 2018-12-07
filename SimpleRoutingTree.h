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
	MAX_QUERIES = 2,
///////////////////////////////////////
	SUM = 1,
	MAX = 2,
	MIN = 3,
	COUNT = 4,
	AVG = 5,
	VAR = 6,
//////////////////////////////////////
};

// Struct for RoutingMsg
typedef nx_struct TinaRoutingMsg
{
	nx_uint8_t mode;
	nx_uint8_t select;
	nx_uint8_t tct;
	nx_uint8_t depth;
} TinaRoutingMsg;

typedef nx_struct extendRoutingMsg1Q
{
	nx_uint8_t mode;
	nx_uint8_t select;
	nx_uint8_t depth;
} extendRoutingMsg1Q;

typedef nx_struct extendRoutingMsg2Q
{
	nx_uint8_t mode;
	nx_uint8_t select[MAX_QUERIES];
	nx_uint8_t depth;
} extendRoutingMsg2Q;

// Struct for ChildInfo
typedef struct ChildInfo
{
    nx_uint16_t childID;
    nx_uint16_t sum;
    nx_uint8_t count;
    nx_uint8_t max;
    nx_uint8_t min;
    nx_uint32_t sumsq;
} ChildInfo;

// Struct for MeasMsg
typedef nx_struct OneMeas8bit 
{
        nx_uint8_t measurement;
} OneMeas8bit;

typedef nx_struct OneMeas16bit 
{
        nx_uint16_t measurement;
} OneMeas16bit;

typedef nx_struct TwoMeas8bit
{
        nx_uint8_t measurement1;
        nx_uint8_t measurement2;
} TwoMeas8bit;

typedef nx_struct TwoMeasMixedbit
{
        nx_uint16_t measurement16bit;
        nx_uint8_t measurement8bit;
} TwoMeasMixedbit;

typedef nx_struct ThreeMeasMixedbit
{
        nx_uint16_t measurement16bit;
        nx_uint8_t measurement8bit1;
        nx_uint8_t measurement8bit2;
} ThreeMeasMixedbit;

typedef nx_struct VarMeasSimple
{
        nx_uint32_t measurement32bit;
        nx_uint16_t measurement16bit;
        nx_uint8_t measurement8bit;
} VarMeasSimple;

typedef nx_struct VarMeasDouble
{
        nx_uint32_t measurement32bit;
        nx_uint16_t measurement16bit;
        nx_uint8_t measurement8bit1;
		nx_uint8_t measurement8bit2;
} VarMeasDouble;

#endif

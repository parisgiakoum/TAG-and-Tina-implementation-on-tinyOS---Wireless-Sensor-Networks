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
	SUMSQ = 7,
//////////////////////////////////////
};

// Tina mode
typedef nx_struct Routing4field
{
	nx_uint8_t mode;
	nx_uint8_t select;
	nx_uint8_t select2ortct;
	nx_uint8_t depth;
} Routing4field;

// Extended mode - 1 query
typedef nx_struct Routing3field
{
	nx_uint8_t mode;
	nx_uint8_t select;
	nx_uint8_t depth;
} Routing3field;

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

// MIN || MAX || COUNT
typedef nx_struct OneMeas8bit 
{
        nx_uint8_t measurement;
} OneMeas8bit;

// SUM
typedef nx_struct OneMeas16bit 
{
        nx_uint16_t measurement;
} OneMeas16bit;

// MIN-MAX-COUNT (PAIR)
typedef nx_struct TwoMeas8bit
{
        nx_uint8_t measurement1;
        nx_uint8_t measurement2;
        // flag
        nx_uint8_t measurementQueries[MAX_QUERIES];
} TwoMeas8bit;

// AVG || SUM - (MIN || MAX || COUNT || AVG) || AVG - COUNT
typedef nx_struct TwoMeasMixedbit
{
        nx_uint16_t measurement16bit;
        nx_uint8_t measurement8bit;
} TwoMeasMixedbit;

// AVG - MAX || AVG - MIN
typedef nx_struct ThreeMeasMixedbit
{
        nx_uint16_t measurement16bit;
        nx_uint8_t measurement8bit1;
        nx_uint8_t measurement8bit2;
} ThreeMeasMixedbit;

// VAR || VAR - AVG || VAR - SUM || VAR - COUNT
typedef nx_struct VarMeasSimple
{
        nx_uint32_t measurement32bit;
        nx_uint16_t measurement16bit;
        nx_uint8_t measurement8bit;
} VarMeasSimple;

// VAR - MIN || VAR - MAX
typedef nx_struct VarMeasDouble
{
        nx_uint32_t measurement32bit;
        nx_uint16_t measurement16bit;
        nx_uint8_t measurement8bit1;
		nx_uint8_t measurement8bit2;
} VarMeasDouble;

#endif

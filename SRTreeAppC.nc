#include "SimpleRoutingTree.h"

configuration SRTreeAppC @safe() { }
implementation{
	components SRTreeC;

#if defined(DELUGE) //defined(DELUGE_BASESTATION) || defined(DELUGE_LIGHT_BASESTATION)
	components DelugeC;
#endif

#ifdef PRINTFDBG_MODE
		components PrintfC;
#endif
	// Standard Component Declaration
	components MainC, LedsC, ActiveMessageC, RandomC;

	// Timer Declarations
	components new TimerMilliC() as RoutingMsgTimerC;
	components new TimerMilliC() as RoundTimerC;
	components new TimerMilliC() as SendMeasTimerC;
	
	// Message Declarations
	components new AMSenderC(AM_ROUTINGMSG) as RoutingSenderC;
	components new AMReceiverC(AM_ROUTINGMSG) as RoutingReceiverC;
	components new AMSenderC(AM_MEASMSG) as MeasSenderC;
	components new AMReceiverC(AM_MEASMSG) as MeasReceiverC;

	// Packet Declarations
	components new PacketQueueC(SENDER_QUEUE_SIZE) as RoutingSendQueueC;
	components new PacketQueueC(RECEIVER_QUEUE_SIZE) as RoutingReceiveQueueC;
	components new PacketQueueC(SENDER_QUEUE_SIZE) as MeasSendQueueC;
	components new PacketQueueC(RECEIVER_QUEUE_SIZE) as MeasReceiveQueueC;
	
	// Wiring
	// Boot
	SRTreeC.Boot->MainC.Boot;
	
	// Radio
	SRTreeC.RadioControl -> ActiveMessageC;

	// Random
	SRTreeC.Random->RandomC;
	
	// Timers
	SRTreeC.RoutingMsgTimer->RoutingMsgTimerC;
	SRTreeC.RoundTimer->RoundTimerC;
	SRTreeC.SendMeasTimer->SendMeasTimerC;

	// RoutingMsg
	SRTreeC.RoutingPacket->RoutingSenderC.Packet;
	SRTreeC.RoutingAMPacket->RoutingSenderC.AMPacket;
	SRTreeC.RoutingAMSend->RoutingSenderC.AMSend;
	SRTreeC.RoutingReceive->RoutingReceiverC.Receive;
	
	// MeasMsg
	SRTreeC.MeasPacket->MeasSenderC.Packet;
	SRTreeC.MeasAMPacket->MeasSenderC.AMPacket;
	SRTreeC.MeasAMSend->MeasSenderC.AMSend;
	SRTreeC.MeasReceive->MeasReceiverC.Receive;	

	// Queues
	SRTreeC.RoutingSendQueue->RoutingSendQueueC;
	SRTreeC.RoutingReceiveQueue->RoutingReceiveQueueC;
	SRTreeC.MeasSendQueue->MeasSendQueueC;
	SRTreeC.MeasReceiveQueue->MeasReceiveQueueC;
	
}

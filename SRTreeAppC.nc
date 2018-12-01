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
	components MainC, LedsC, ActiveMessageC, RandomC;

	components new TimerMilliC() as RoutingMsgTimerC;
	components new TimerMilliC() as RoundTimerC;
	components new TimerMilliC() as SendMeasTimerC;
	
	components new AMSenderC(AM_ROUTINGMSG) as RoutingSenderC;
	components new AMReceiverC(AM_ROUTINGMSG) as RoutingReceiverC;
	components new AMSenderC(AM_MEASMSG) as MeasSenderC;
	components new AMReceiverC(AM_MEASMSG) as MeasReceiverC;

	components new PacketQueueC(SENDER_QUEUE_SIZE) as RoutingSendQueueC;
	components new PacketQueueC(RECEIVER_QUEUE_SIZE) as RoutingReceiveQueueC;
	components new PacketQueueC(SENDER_QUEUE_SIZE) as MeasSendQueueC;
	components new PacketQueueC(RECEIVER_QUEUE_SIZE) as MeasReceiveQueueC;
	
	SRTreeC.Boot->MainC.Boot;
	
	SRTreeC.RadioControl -> ActiveMessageC;

	SRTreeC.Random->RandomC;
	
	SRTreeC.RoutingMsgTimer->RoutingMsgTimerC;
	SRTreeC.RoundTimer->RoundTimerC;
	SRTreeC.SendMeasTimer->SendMeasTimerC;

	SRTreeC.RoutingPacket->RoutingSenderC.Packet;
	SRTreeC.RoutingAMPacket->RoutingSenderC.AMPacket;
	SRTreeC.RoutingAMSend->RoutingSenderC.AMSend;
	SRTreeC.RoutingReceive->RoutingReceiverC.Receive;
	
	SRTreeC.MeasPacket->MeasSenderC.Packet;
	SRTreeC.MeasAMPacket->MeasSenderC.AMPacket;
	SRTreeC.MeasAMSend->MeasSenderC.AMSend;
	SRTreeC.MeasReceive->MeasReceiverC.Receive;	

	SRTreeC.RoutingSendQueue->RoutingSendQueueC;
	SRTreeC.RoutingReceiveQueue->RoutingReceiveQueueC;
	SRTreeC.MeasSendQueue->MeasSendQueueC;
	SRTreeC.MeasReceiveQueue->MeasReceiveQueueC;

	
}

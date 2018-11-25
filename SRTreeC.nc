#include "SimpleRoutingTree.h"
#ifdef PRINTFDBG_MODE
	#include "printf.h"
#endif

module SRTreeC
{
	uses interface Boot;
	uses interface SplitControl as RadioControl;

	uses interface Packet as RoutingPacket;
	uses interface AMSend as RoutingAMSend;
	uses interface AMPacket as RoutingAMPacket;
	
	uses interface AMSend as NotifyAMSend;
	uses interface AMPacket as NotifyAMPacket;
	uses interface Packet as NotifyPacket;

	uses interface Timer<TMilli> as RoutingMsgTimer;
	uses interface Timer<TMilli> as EpochTimer;
	uses interface Timer<TMilli> as SendMeasTimer;
	
	uses interface Receive as RoutingReceive;
	uses interface Receive as NotifyReceive;
	
	uses interface PacketQueue as RoutingSendQueue;
	uses interface PacketQueue as RoutingReceiveQueue;
	
	uses interface PacketQueue as NotifySendQueue;
	uses interface PacketQueue as NotifyReceiveQueue;
}
implementation
{
	uint16_t  roundCounter;
	
	message_t radioRoutingSendPkt;
	message_t radioNotifySendPkt;
	
	bool RoutingSendBusy=FALSE;
	bool NotifySendBusy=FALSE;
	bool FinishedRouting = FALSE;
	
	uint8_t curdepth;
	uint16_t parentID;
	
	task void sendRoutingTask();
	task void sendNotifyTask();
	task void receiveRoutingTask();
	task void receiveNotifyTask();

////////////////////	
	event void Boot.booted()
	{
		/////// arxikopoiisi radio
		call RadioControl.start();
		

		roundCounter =0;
		
		if(TOS_NODE_ID==0)
		{
			curdepth=0;
			parentID=0;
			dbg("Boot", "curdepth = %d  ,  parentID= %d \n", curdepth , parentID);
#ifdef PRINTFDBG_MODE
			printf("Booted NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
			printfflush();
#endif
		}
		else
		{
			curdepth=-1;
			parentID=-1;
			dbg("Boot", "curdepth = %d  ,  parentID= %d \n", curdepth , parentID);
#ifdef PRINTFDBG_MODE
			printf("Booted NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
			printfflush();
#endif
		}
	}
	
///////////////////
	event void RadioControl.startDone(error_t err)
	{
		if (err == SUCCESS)
		{
			dbg("Radio" , "Radio initialized successfully!!!\n");
#ifdef PRINTFDBG_MODE
			printf("Radio initialized successfully!!!\n");
			printfflush();
#endif

			call EpochTimer.startPeriodic(TIMER_PERIOD_MILLI);
			call SendMeasTimer.startOneShot(TIMER_ROUTING_DURATION);

			
			//call RoutingMsgTimer.startOneShot(TIMER_PERIOD_MILLI);
			//call RoutingMsgTimer.startPeriodic(TIMER_PERIOD_MILLI);
			if (TOS_NODE_ID==0)
			{
				call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
				//dbg("Radio", "GET NOW: %d", call RoutingMsgTimer.getNow());
			}
		}
		else
		{
			dbg("Radio" , "Radio initialization failed! Retrying...\n");
#ifdef PRINTFDBG_MODE
			printf("Radio initialization failed! Retrying...\n");
			printfflush();
#endif
			call RadioControl.start();
		}
	}

///////////////////
	event void RadioControl.stopDone(error_t err)
	{ 
		dbg("Radio", "Radio stopped!\n");
#ifdef PRINTFDBG_MODE
		printf("Radio stopped!\n");
		printfflush();
#endif
	}
	
////////////////////////////
	event void RoutingMsgTimer.fired()
	{
		message_t tmp;
		error_t enqueueDone;
		
		RoutingMsg* mrpkt;
		dbg("SRTreeC", "RoutingMsgTimer fired!\n");
#ifdef PRINTFDBG_MODE
		printfflush();
		printf("RoutingMsgTimer fired!  radioBusy");
		printfflush();
#endif
		roundCounter+=1;

		if (TOS_NODE_ID==0)
		{
			dbg("SRTreeC", "##################################### \n");
			dbg("SRTreeC", "#######   ROUND   %u    ############## \n", roundCounter);
			dbg("SRTreeC", "#####################################\n");
			
			//call RoutingMsgTimer.startOneShot(TIMER_PERIOD_MILLI);
		}
		
		if(call RoutingSendQueue.full())
		{
#ifdef PRINTFDBG_MODE
			printf("RoutingSendQueue is FULL!!! \n");
			printfflush();
#endif
			return;
		}
		
		mrpkt = (RoutingMsg*) (call RoutingPacket.getPayload(&tmp, sizeof(RoutingMsg)));
		if(mrpkt==NULL)
		{
			dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
#ifdef PRINTFDBG_MODE
			printf("RoutingMsgTimer.fired(): No valid payload... \n");
			printfflush();
#endif
			return;
		}
		atomic{
		mrpkt->senderID=TOS_NODE_ID;
		mrpkt->depth = curdepth;
		}
		dbg("SRTreeC" , "Sending RoutingMsg... \n");

#ifdef PRINTFDBG_MODE
		printf("NodeID= %d : RoutingMsg sending...!!!! \n", TOS_NODE_ID);
		printfflush();
#endif		
		
		// Enqueue
		enqueueDone=call RoutingSendQueue.enqueue(tmp);
		
		if( enqueueDone==SUCCESS)
		{
			if (call RoutingSendQueue.size()==1)
			{
				dbg("SRTreeC", "SendTask() posted!!\n");
#ifdef PRINTFDBG_MODE
				printf("SendTask() posted!!\n");
				printfflush();
#endif
				post sendRoutingTask();
			}
			
			dbg("SRTreeC","RoutingMsg enqueued successfully in SendingQueue!!!\n");
#ifdef PRINTFDBG_MODE
			printf("RoutingMsg enqueued successfully in SendingQueue!!!\n");
			printfflush();
#endif
		}
		else
		{
			dbg("SRTreeC","RoutingMsg failed to be enqueued in SendingQueue!!!");
#ifdef PRINTFDBG_MODE			
			printf("RoutingMsg failed to be enqueued in SendingQueue!!!\n");
			printfflush();
#endif
		}		
	}
	

///////////////////////
	event void RoutingAMSend.sendDone(message_t * msg , error_t err)
	{

		dbg("SRTreeC" , "Package sent %s \n", (err==SUCCESS)?"True":"False");
#ifdef PRINTFDBG_MODE
		printf("Package sent %s \n", (err==SUCCESS)?"True":"False");
		printfflush();
#endif

		if(!(call RoutingSendQueue.empty()))
		{
			post sendRoutingTask();
		}		
	}

/////////////////////////////	
	event void NotifyAMSend.sendDone(message_t *msendDonesg , error_t err)
	{
		dbg("SRTreeC", "A Notify package sent... %s \n",(err==SUCCESS)?"True":"False");
#ifdef PRINTFDBG_MODE
		printf("A Notify package sent... %s \n",(err==SUCCESS)?"True":"False");
		printfflush();
#endif
		
	
		dbg("SRTreeC" , "Package sent %s \n", (err==SUCCESS)?"True":"False");
#ifdef PRINTFDBG_MODE
		printf("Package sent %s \n", (err==SUCCESS)?"True":"False");
		printfflush();
#endif
		
		if(!(call NotifySendQueue.empty()))
		{
			post sendNotifyTask();
		}
	}


///////////////////////////	
	event message_t* NotifyReceive.receive( message_t* msg , void* payload , uint8_t len)
	{
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;
		
		msource = call NotifyAMPacket.source(msg);
		
		dbg("SRTreeC", "### NotifyReceive.receive() start ##### \n");
		dbg("SRTreeC", "Something received!!!  from %u   %u \n",((NotifyParentMsg*) payload)->senderID, msource);
#ifdef PRINTFDBG_MODE		
		printf("Something Received!!!, len = %u , npm=%u , rm=%u\n",len, sizeof(NotifyParentMsg), sizeof(RoutingMsg));
		printfflush();
#endif

		atomic{
		memcpy(&tmp,msg,sizeof(message_t));
		//tmp=*(message_t*)msg;
		}
		enqueueDone=call NotifyReceiveQueue.enqueue(tmp);
		
		if( enqueueDone== SUCCESS)
		{
#ifdef PRINTFDBG_MODE
			printf("posting receiveNotifyTask()!!!! \n");
			printfflush();
#endif
			post receiveNotifyTask();
		}
		else
		{
			dbg("SRTreeC","NotifyMsg enqueue failed!!! \n");
#ifdef PRINTFDBG_MODE
			printf("NotifyMsg enqueue failed!!! \n");
			printfflush();
#endif			
		}
		
		dbg("SRTreeC", "### NotifyReceive.receive() end ##### \n");
		return msg;
	}


//////////////////////////////
	event message_t* RoutingReceive.receive( message_t * msg , void * payload, uint8_t len)
	{
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;
		
		msource =call RoutingAMPacket.source(msg);
		
		dbg("SRTreeC", "### RoutingReceive.receive() start ##### \n");
		dbg("SRTreeC", "Something received!!!  from %u  %u \n",((RoutingMsg*) payload)->senderID ,  msource);
#ifdef PRINTFDBG_MODE		
		printf("Something Received!!!, len = %u , npm=%u , rm=%u\n",len, sizeof(NotifyParentMsg), sizeof(RoutingMsg));
		printfflush();
#endif		
		atomic{
		memcpy(&tmp,msg,sizeof(message_t));
		//tmp=*(message_t*)msg;
		}
		enqueueDone=call RoutingReceiveQueue.enqueue(tmp);
		if(enqueueDone == SUCCESS)
		{
#ifdef PRINTFDBG_MODE
			printf("posting receiveRoutingTask()!!!! \n");
			printfflush();
#endif
			post receiveRoutingTask();
		}
		else
		{
			dbg("SRTreeC","RoutingMsg enqueue failed!!! \n");
#ifdef PRINTFDBG_MODE
			printf("RoutingMsg enqueue failed!!! \n");
			printfflush();
#endif			
		}		
		dbg("SRTreeC", "### RoutingReceive.receive() end ##### \n");
		return msg;
	}

////////////////////////////////
	event void EpochTimer.fired()
	{
		roundCounter+=1;
		
		if (TOS_NODE_ID!=0) {
			call SendMeasTimer.startOneShot(TIMER_PERIOD_MILLI-((curdepth * TIMER_PERIOD_MILLI)/ MAX_DEPTH));
		}
		else
		{
			dbg("EpochMsg", "IAMZERO\n");
			dbg("EpochMsg", "\n");
			dbg("EpochMsg", "##################################### \n");
			dbg("EpochMsg", "#######   ROUND   %u    ############## \n", roundCounter);
			dbg("EpochMsg", "#####################################\n");
		}
	}

	event void SendMeasTimer.fired()
	{
		if (!FinishedRouting)
		{
			dbg("EpochMsg", "FinishedRouting!\n");
			FinishedRouting=TRUE;
			if (TOS_NODE_ID!=0) 
			{
				call SendMeasTimer.startOneShot((TIMER_PERIOD_MILLI-TIMER_ROUTING_DURATION)-((curdepth * (TIMER_PERIOD_MILLI-TIMER_ROUTING_DURATION))/MAX_DEPTH));
			}
		}
		else
		{
			dbg("EpochMsg", "NodeID = %d curdepth= %d\n", TOS_NODE_ID, curdepth);
			dbg("EpochMsg", "Starting Data transmission to parent!\n");
		}
	}

	////////////// Tasks implementations //////////////////////////////
	
	
/////////////
	task void sendRoutingTask()
	{
		error_t sendDone;
		//message_t radioRoutingSendPkt;
		
#ifdef PRINTFDBG_MODE
		printf("SendRoutingTask(): Starting....\n");
		printfflush();
#endif
		if (call RoutingSendQueue.empty())
		{
			dbg("SRTreeC","sendRoutingTask(): Q is empty!\n");
#ifdef PRINTFDBG_MODE		
			printf("sendRoutingTask():Q is empty!\n");
			printfflush();
#endif
			return;
		}
				
		radioRoutingSendPkt = call RoutingSendQueue.dequeue();

		sendDone=call RoutingAMSend.send(AM_BROADCAST_ADDR,&radioRoutingSendPkt,sizeof(RoutingMsg));
		
		if ( sendDone== SUCCESS)
		{
			dbg("SRTreeC","sendRoutingTask(): Send returned success!!!\n");
#ifdef PRINTFDBG_MODE
			printf("sendRoutingTask(): Send returned success!!!\n");
			printfflush();
#endif
		}
		else
		{
			dbg("SRTreeC","send failed!!!\n");
#ifdef PRINTFDBG_MODE
			printf("SendRoutingTask(): send failed!!!\n");
#endif
		}
	}

///////////////////////////////////////
	/**
	 * dequeues a message and sends it
	 */
	task void sendNotifyTask()
	{
		uint8_t mlen;//, skip;
		error_t sendDone;
		uint16_t mdest;
		NotifyParentMsg* mpayload;
		
		//message_t radioNotifySendPkt;
		
#ifdef PRINTFDBG_MODE
		printf("SendNotifyTask(): going to send one more package.\n");
		printfflush();
#endif
		if (call NotifySendQueue.empty())
		{
			dbg("SRTreeC","sendNotifyTask(): Q is empty!\n");
#ifdef PRINTFDBG_MODE		
			printf("sendNotifyTask():Q is empty!\n");
			printfflush();
#endif
			return;
		}
		
		radioNotifySendPkt = call NotifySendQueue.dequeue();
		
		mlen=call NotifyPacket.payloadLength(&radioNotifySendPkt);
		
		mpayload= call NotifyPacket.getPayload(&radioNotifySendPkt,mlen);
		
		if(mlen!= sizeof(NotifyParentMsg))
		{
			dbg("SRTreeC", "\t\t sendNotifyTask(): Unknown message!!\n");
#ifdef PRINTFDBG_MODE
			printf("\t\t sendNotifyTask(): Unknown message!!\n");
			printfflush();
#endif
			return;
		}
		
		dbg("SRTreeC" , " sendNotifyTask(): mlen = %u  senderID= %u \n",mlen,mpayload->senderID);
#ifdef PRINTFDBG_MODE
		printf("\t\t\t\t sendNotifyTask(): mlen=%u\n",mlen);
		printfflush();
#endif
		mdest= call NotifyAMPacket.destination(&radioNotifySendPkt);
		
		
		sendDone=call NotifyAMSend.send(mdest,&radioNotifySendPkt, mlen);
		
		if ( sendDone== SUCCESS)
		{
			dbg("SRTreeC","sendNotifyTask(): Send returned success!!!\n");
#ifdef PRINTFDBG_MODE
			printf("sendNotifyTask(): Send returned success!!!\n");
			printfflush();
#endif
		}
		else
		{
			dbg("SRTreeC","send failed!!!\n");
#ifdef PRINTFDBG_MODE
			printf("SendNotifyTask(): send failed!!!\n");
#endif
		}
	}


	////////////////////////////////////////////////////////////////////
	//*****************************************************************/
	///////////////////////////////////////////////////////////////////
	/**
	 * dequeues a message and processes it
	 */
	
	task void receiveRoutingTask()
	{
		uint8_t len;
		message_t radioRoutingRecPkt;
		
#ifdef PRINTFDBG_MODE
		printf("ReceiveRoutingTask():received msg...\n");
		printfflush();
#endif
		radioRoutingRecPkt= call RoutingReceiveQueue.dequeue();
		
		len= call RoutingPacket.payloadLength(&radioRoutingRecPkt);
		
		dbg("SRTreeC","ReceiveRoutingTask(): len=%u \n",len);
#ifdef PRINTFDBG_MODE
		printf("ReceiveRoutingTask(): len=%u!\n",len);
		printfflush();
#endif
		// processing of radioRecPkt
		
		// pos tha xexorizo ta 2 diaforetika minimata???
				
		if(len == sizeof(RoutingMsg))
		{
			RoutingMsg * mpkt = (RoutingMsg*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
			
			//if(TOS_NODE_ID >0)
			//{
				//call RoutingMsgTimer.startOneShot(TIMER_PERIOD_MILLI);
			//}
			//
			
			dbg("SRTreeC" , "receiveRoutingTask():senderID= %d , depth= %d \n", mpkt->senderID , mpkt->depth);
#ifdef PRINTFDBG_MODE
			printf("NodeID= %d , RoutingMsg received! \n",TOS_NODE_ID);
			printf("receiveRoutingTask():senderID= %d , depth= %d \n", mpkt->senderID , mpkt->depth);
			printfflush();
#endif
			if ( (parentID<0)||(parentID>=65535))
			{
				// tote den exei akoma patera
				parentID= call RoutingAMPacket.source(&radioRoutingRecPkt);//mpkt->senderID;q
				curdepth= mpkt->depth + 1;
				dbg("SRTreeC" , "NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
#ifdef PRINTFDBG_MODE
				printf("NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
				printfflush();
#endif
	

				call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
			}
			else
			{
				dbg("SRTreeC" , "NodeID= %d : Already has a parent: curdepth= %d, parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
			}
							
		}
		else
		{
			dbg("SRTreeC","receiveRoutingTask():Empty message!!! \n");
#ifdef PRINTFDBG_MODE
			printf("receiveRoutingTask():Empty message!!! \n");
			printfflush();
#endif
			return;
		}
		
	}


////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////	
	
	 
	task void receiveNotifyTask()
	{
		message_t tmp;
		uint8_t len;
		message_t radioNotifyRecPkt;
		
#ifdef PRINTFDBG_MODE
		printf("ReceiveNotifyTask():received msg...\n");
		printfflush();
#endif
		radioNotifyRecPkt= call NotifyReceiveQueue.dequeue();
		
		len= call NotifyPacket.payloadLength(&radioNotifyRecPkt);
		
		dbg("SRTreeC","ReceiveNotifyTask(): len=%u \n",len);
#ifdef PRINTFDBG_MODE
		printf("ReceiveNotifyTask(): len=%u!\n",len);
		printfflush();
#endif
		if(len == sizeof(NotifyParentMsg))
		{
			// an to parentID== TOS_NODE_ID tote
			// tha proothei to minima pros tin riza xoris broadcast
			// kai tha ananeonei ton tyxon pinaka paidion..
			// allios tha diagrafei to paidi apo ton pinaka paidion
			
			NotifyParentMsg* mr = (NotifyParentMsg*) (call NotifyPacket.getPayload(&radioNotifyRecPkt,len));
			
			dbg("SRTreeC" , "NotifyParentMsg received from %d !!! \n", mr->senderID);
#ifdef PRINTFDBG_MODE
			printf("NodeID= %d NotifyParentMsg from senderID = %d!!! \n",TOS_NODE_ID , mr->senderID);
			printfflush();
#endif
			if ( mr->parentID == TOS_NODE_ID)
			{
				// tote prosthiki stin lista ton paidion.
				
			}
			else
			{
				// apla diagrafei ton komvo apo paidi tou..
				
			}
			if ( TOS_NODE_ID==0)
			{

			}
			else
			{
				NotifyParentMsg* m;
				memcpy(&tmp,&radioNotifyRecPkt,sizeof(message_t));
				
				m = (NotifyParentMsg *) (call NotifyPacket.getPayload(&tmp, sizeof(NotifyParentMsg)));
				//m->senderID=mr->senderID;
				//m->depth = mr->depth;
				//m->parentID = mr->parentID;
				
				dbg("SRTreeC" , "Forwarding NotifyParentMsg from senderID= %d  to parentID=%d \n" , m->senderID, parentID);
#ifdef PRINTFDBG_MODE
				printf("NotifyParentMsg NodeID= %d sent!\n", TOS_NODE_ID);
				printfflush();
#endif
				call NotifyAMPacket.setDestination(&tmp, parentID);
				call NotifyPacket.setPayloadLength(&tmp,sizeof(NotifyParentMsg));
				
				if (call NotifySendQueue.enqueue(tmp)==SUCCESS)
				{
					dbg("SRTreeC", "receiveNotifyTask(): NotifyParentMsg enqueued in SendingQueue successfully!!!\n");
					if (call NotifySendQueue.size() == 1)
					{
						post sendNotifyTask();
					}
				}

				
			}
			
		}
		else
		{
			dbg("SRTreeC","receiveNotifyTask():Empty message!!! \n");
#ifdef PRINTFDBG_MODE
			printf("receiveNotifyTask():Empty message!!! \n");
			printfflush();
#endif
			return;
		}
		
	}
	
}

#include "SimpleRoutingTree.h"
#ifdef PRINTFDBG_MODE
	#include "printf.h"
#endif

module SRTreeC
{
	uses interface Boot;
	uses interface SplitControl as RadioControl;

	uses interface Random;

	uses interface Packet as RoutingPacket;
	uses interface AMSend as RoutingAMSend;
	uses interface AMPacket as RoutingAMPacket;

	uses interface AMSend as MeasAMSend;
	uses interface AMPacket as MeasAMPacket;
	uses interface Packet as MeasPacket;

	uses interface Timer<TMilli> as RoutingMsgTimer;
	uses interface Timer<TMilli> as RoundTimer;
	uses interface Timer<TMilli> as SendMeasTimer;
	
	uses interface Receive as RoutingReceive;
	uses interface Receive as MeasReceive;

	uses interface PacketQueue as RoutingSendQueue;
	uses interface PacketQueue as RoutingReceiveQueue;

	uses interface PacketQueue as MeasSendQueue;
	uses interface PacketQueue as MeasReceiveQueue;
}
implementation
{
	uint16_t  roundCounter;
	
	message_t radioRoutingSendPkt;
	message_t radioMeasSendPkt;
	
	bool RoutingSendBusy=FALSE;
	bool FinishedRouting = FALSE;
	
	uint8_t curdepth;
	uint16_t parentID;

	uint16_t measurement;

	ChildMsg children[MAX_CHILDREN];
	
	task void sendRoutingTask();
	task void receiveRoutingTask();
	task void sendMeasTask();
	task void receiveMeasTask();


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
		uint8_t i;

		if (err == SUCCESS)
		{
			dbg("Radio" , "Radio initialized successfully!!!\n");
#ifdef PRINTFDBG_MODE
			printf("Radio initialized successfully!!!\n");
			printfflush();
#endif

		for (i=0; i < MAX_CHILDREN; i++)
		{
			children[i].senderID = 0;
			children[i].sum = 0;
			children[i].count = 0;
			children[i].max = 0;

			dbg("Tests", "Init child: %d, senderID: %d, sum: %d, count: %d, max: %d\n", i, children[i].senderID, children[i].sum, children[i].count, children[i].max);
		}

			call SendMeasTimer.startOneShot(TIMER_ROUTING_DURATION);
			call RoundTimer.startPeriodicAt(-(BOOT_TIME), TIMER_PERIOD_MILLI);

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
			dbg("RoutingMsg", "##################################### \n");
			dbg("RoutingMsg", "#######   ROUND   %u    ############## \n", roundCounter);
			dbg("RoutingMsg", "#####################################\n");
			
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


//////////////////////////////
	event message_t* RoutingReceive.receive( message_t * msg , void * payload, uint8_t len)
	{
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;
		
		msource =call RoutingAMPacket.source(msg);
		
		dbg("SRTreeC", "### RoutingReceive.receive() start ##### \n");
		dbg("SRTreeC", "Something received!!!  from %u  %u \n",((RoutingMsg*) payload)->senderID ,  msource);
		
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

/////////////////
	event void RoundTimer.fired()
	{
		if (TOS_NODE_ID == 0)
		{
			roundCounter++;
			dbg("Measurements", "##################################### \n");
			dbg("Measurements", "#######   ROUND   %u    ############## \n", roundCounter);
			dbg("Measurements", "#####################################\n");
		}
	}

/////////////////
	event void SendMeasTimer.fired()
	{
		message_t tmp;
		error_t enqueueDone;
		MeasMsg *measpkt;
		uint8_t count, i, max;
		uint16_t sum;
		float avg;

		if (!FinishedRouting)
		{
			dbg("RoutingMsg", "FinishedRouting!\n");
			FinishedRouting = TRUE;
			call SendMeasTimer.startPeriodicAt(((-(BOOT_TIME)-((curdepth+1)*TIMER_FAST_PERIOD))+(TOS_NODE_ID*3)), TIMER_PERIOD_MILLI);
		}
		else
		{
			dbg("Measurements", "NodeID = %d curdepth= %d\n", TOS_NODE_ID, curdepth);
			dbg("Measurements", "Starting Data transmission to parent!\n");
			
			dbg("SRTreeC", "SendMeasTimer fired!\n");

			measurement = (call Random.rand16())%50;
			dbg("Measurements", "measurement is: %d\n", measurement);

			if(call MeasSendQueue.full())
			{
				dbg("SRTreeC", "MeasSendQueue full!\n");
				return;
			}
		
			measpkt = (MeasMsg*) (call MeasPacket.getPayload(&tmp, sizeof(MeasMsg)));
			if(measpkt==NULL)
			{
				dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
				return;
			}


			atomic
			{
				sum = measurement;
				count = 1;
				max = measurement;

				for (i=0; i < MAX_CHILDREN && children[i].senderID != 0; i++)
				{
					dbg("Measurements" , "Child %d has sum: %d, count: %d and max: %d\n", children[i].senderID, children[i].sum, children[i].count, children[i].max);

					sum += children[i].sum;
					count += children[i].count;
					max = (max > children[i].max) ? max : children[i].max;
				}
				dbg("Measurements" , "Node has sum: %d, count: %d, max: %d\n", sum, count, max);
			}

			if (TOS_NODE_ID == 0)
			{
				avg = (float) sum / count;
				dbg("Measurements", "\n");
				dbg("Measurements" , "FINAL RESULTS: AVG: %.2f , Max: %d\n", avg, max);
				dbg("Measurements", "\n");
			}
			else
			{
				atomic
				{
					measpkt->sum = sum;
					measpkt->count = count;
					measpkt->max = max;
				}
				
				dbg("SRTreeC" , "Sending MeasMsg... \n");
				
				call MeasAMPacket.setDestination(&tmp, parentID);
				call MeasPacket.setPayloadLength(&tmp,sizeof(MeasMsg));

				// Enqueue
				enqueueDone=call MeasSendQueue.enqueue(tmp);
		
				if( enqueueDone==SUCCESS)
				{
					if (call MeasSendQueue.size()==1)
					{
						dbg("SRTreeC", "SendMeasTask() posted!!\n");
						post sendMeasTask();
					}
					
					dbg("SRTreeC","MeasMsg enqueued successfully in MeasSendQueue!!!\n");
				}
				else
				{
					dbg("SRTreeC","MeasMsg failed to be enqueued in MeasSendQueue!!!");
				}		
			}
		}
	}


/////////////////////////////	
	event void MeasAMSend.sendDone(message_t *msendDonesg , error_t err)
	{
		dbg("SRTreeC", "A Measure package sent... %s \n",(err==SUCCESS)?"True":"False");		
		
		if(!(call MeasSendQueue.empty()))
		{
			post sendMeasTask();
		}
	}

/////////////////////////////	
	event message_t* MeasReceive.receive( message_t* msg , void* payload , uint8_t len)
	{
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;
		
		msource = call MeasAMPacket.source(msg);
		
		dbg("SRTreeC", "### MeasReceive.receive() start ##### \n");
		dbg("SRTreeC", "Some measurement received!!!  from %u \n", msource);

		atomic
		{
			memcpy(&tmp,msg,sizeof(message_t));
			//tmp=*(message_t*)msg;
		}
		
		enqueueDone=call MeasReceiveQueue.enqueue(tmp);
		
		if( enqueueDone== SUCCESS)
		{
			post receiveMeasTask();
		}
		else
		{
			dbg("SRTreeC","MeasMsg enqueue failed!!! \n");			
		}
		
		dbg("SRTreeC", "### MeasReceive.receive() end ##### \n");
		return msg;
	}

	////////////////////////////////////////////////////////////////////
	////////////// Tasks implementations //////////////////////////////
	///////////////////////////////////////////////////////////////////
	
	
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

			if ( (parentID<0)||(parentID>=65535))
			{
				// tote den exei akoma patera
				parentID= call RoutingAMPacket.source(&radioRoutingRecPkt);//mpkt->senderID;q
				curdepth= mpkt->depth + 1;
				dbg("RoutingMsg" , "New parent for NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
	

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
			return;
		}
		
	}


////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////	

	task void sendMeasTask()
	{
		uint8_t mlen;//, skip;
		error_t sendDone;
		uint16_t mdest;
		MeasMsg* mpayload;
		
		if (call MeasSendQueue.empty())
		{
			dbg("SRTreeC","sendMeasTask(): Q is empty!\n");
			return;
		}
		
		radioMeasSendPkt = call MeasSendQueue.dequeue();
		
		mlen=call MeasPacket.payloadLength(&radioMeasSendPkt);
		
		mpayload= call MeasPacket.getPayload(&radioMeasSendPkt,mlen);
		
		if(mlen!= sizeof(MeasMsg))
		{
			dbg("SRTreeC", "\t\t sendMeasTask(): Unknown message!!\n");
			return;
		}
		
		dbg("SRTreeC" , " sendMeasTask(): mlen = %u  sum= %d count= %d max=%d \n",mlen,mpayload->sum,mpayload->count,mpayload->max);
		mdest= call MeasAMPacket.destination(&radioMeasSendPkt);
		
		
		sendDone = call MeasAMSend.send(mdest,&radioMeasSendPkt, mlen);
		
		if ( sendDone == SUCCESS)
		{
			dbg("SRTreeC","sendMeasTask(): Send measure returned success!!!\n");
		}
		else
		{
			dbg("SRTreeC","send measure failed!!!\n");
		}
	}


////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////	
	task void receiveMeasTask()
	{
		message_t tmp;
		uint8_t len, i;
		message_t radioMeasRecPkt;
		uint16_t msource;
		

		radioMeasRecPkt= call MeasReceiveQueue.dequeue();
		
		len= call MeasPacket.payloadLength(&radioMeasRecPkt);
		msource = call MeasAMPacket.source(&radioMeasRecPkt);
		
		dbg("SRTreeC","receiveMeasTask(): len=%u \n",len);

		if(len == sizeof(MeasMsg))
		{
			
			MeasMsg* mr = (MeasMsg*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));
			
			dbg("SRTreeC" , "MeasMsg received from %d !!! \n", msource);


			for (i=0; i < MAX_CHILDREN; i++)
			{
				if (children[i].senderID == msource || children[i].senderID == 0)
				{
					if (children[i].senderID==0)
					{
						children[i].senderID = msource;
					}
					children[i].sum = mr->sum;
					children[i].count = mr->count;
					children[i].max = mr->max;

					dbg("Measurements" , "Receive from child: %d values - sum:%d, count: %d, max: %d\n", children[i].senderID, children[i].sum, children[i].count, children[i].max);
					break;
				}
			}
		}
		else
		{
			dbg("SRTreeC","receiveMeasTask():Empty message!!! \n");
			return;
		}
	}
}


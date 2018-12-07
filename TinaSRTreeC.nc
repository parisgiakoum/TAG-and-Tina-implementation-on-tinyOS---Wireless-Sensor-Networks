#include "SimpleRoutingTree.h"
#ifdef PRINTFDBG_MODE
	#include "printf.h"
#endif

module SRTreeC
{
	// Interfaces used

	uses interface Boot;
	uses interface SplitControl as RadioControl;

	uses interface Random;
	uses interface ParameterInit<uint16_t> as Seed;

	uses interface Packet as RoutingPacket;
	uses interface AMSend as RoutingAMSend;
	uses interface AMPacket as RoutingAMPacket;

	uses interface AMSend as MeasAMSend;
	uses interface AMPacket as MeasAMPacket;
	uses interface Packet as MeasPacket;

	uses interface Timer<TMilli> as RoutingMsgTimer;
	uses interface Timer<TMilli> as RoundTimer;
	uses interface Timer<TMilli> as SendMeasTimer;

	uses interface LocalTime<TMilli> as TimeNow;
	
	uses interface Receive as RoutingReceive;
	uses interface Receive as MeasReceive;

	uses interface PacketQueue as RoutingSendQueue;
	uses interface PacketQueue as RoutingReceiveQueue;

	uses interface PacketQueue as MeasSendQueue;
	uses interface PacketQueue as MeasReceiveQueue;
}
implementation
{
	uint16_t  roundCounter;	// Counter holding current round on node 0
	
	// RoutingMsg and MeasMsg messages
	message_t radioRoutingSendPkt;
	message_t radioMeasSendPkt;
	
	// Flag showing if routing is finished on first round
	bool FinishedRouting = FALSE;

	uint8_t curdepth;
	uint16_t parentID;

	// Measurement of node
	uint8_t measurement;
	uint16_t previousQuery16bit;
	uint8_t previousQuery8bit;

	uint8_t tct;
	uint8_t tinaSelect;

	// Array holding children received
	ChildInfo children[MAX_CHILDREN];
	
	// Tasks
	task void sendRoutingTask();
	task void receiveRoutingTask();
	task void sendMeasTask();
	task void receiveMeasTask();


////////////////////	
	event void Boot.booted()
	{
		uint16_t seedNum;
		FILE *f;

		/////// arxikopoiisi radio
		call RadioControl.start();

		roundCounter = 0;
		
		f = fopen("/dev/urandom", "r");
		fread(&seedNum, sizeof(seedNum), 1, f);
		fclose(f);

		call Seed.init(seedNum + TOS_NODE_ID + 1);

		// Node initialisation
		if(TOS_NODE_ID==0)
		{
			curdepth=0;
			parentID=0;
			dbg("Boot", "curdepth = %d  ,  parentID= %d \n", curdepth , parentID);
		}
		else
		{
			curdepth=-1;
			parentID=-1;
			dbg("Boot", "curdepth = %d  ,  parentID= %d \n", curdepth , parentID);
		}
	}

///////////////////
	event void RadioControl.startDone(error_t err)
	{
		uint8_t i;

		if (err == SUCCESS)
		{
			dbg("Radio" , "Radio initialized successfully!!!\n");

			// Children initialisation (childID=0 means no child)
			for (i=0; i < MAX_CHILDREN; i++)
			{
				children[i].childID = 0;
				children[i].sum = 0;
				children[i].count = 0;
				children[i].max = 0;
				children[i].min = 0;

				dbg("Tests", "Init child: %d, childID: %d, sum: %d, count: %d, max: %d\n", i, children[i].childID, children[i].sum, children[i].count, children[i].max);
			}

			// Timer to start sending measurements after routing
			call SendMeasTimer.startOneShot(TIMER_ROUTING_DURATION);
			// Timer to change round on new epoch
			call RoundTimer.startPeriodicAt(-(BOOT_TIME), TIMER_PERIOD_MILLI);

			if (TOS_NODE_ID==0)
			{
				// Timer to start sending RoutingMsg
				call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
			}
		}
		else
		{
			// error
			dbg("Radio" , "Radio initialization failed! Retrying...\n");
			call RadioControl.start();
		}
	}

///////////////////
	event void RadioControl.stopDone(error_t err)
	{
		// error
		dbg("Radio", "Radio stopped!\n");
	}
	
////////////////////////////
	event void RoutingMsgTimer.fired()
	{
		message_t tmp;
		error_t enqueueDone;
		
		TinaRoutingMsg* trpkt;
		dbg("SRTreeC", "RoutingMsgTimer fired!\n");

		roundCounter+=1;

		if (TOS_NODE_ID==0)
		{
			tinaSelect = ((call Random.rand16())%4) + 1;
			tct = (call Random.rand16())%51;
			dbg("Tina", "Query selected for TINA is: %d with tct: %d\n", tinaSelect, tct);


			// Round 1

			dbg("RoutingMsg", "##################################### \n");
			dbg("RoutingMsg", "#######   ROUND   %u    ############## \n", roundCounter);
			dbg("RoutingMsg", "#####################################\n");
		}
		
		// error
		if(call RoutingSendQueue.full())
		{
			dbg("SRTreeC", "RoutingSendQueue is FULL!!! \n");
			return;
		}
		
		// get payload for mrpkt
		trpkt = (TinaRoutingMsg*) (call RoutingPacket.getPayload(&tmp, sizeof(TinaRoutingMsg)));
		
		// error
		if(trpkt==NULL)
		{
			dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
			return;
		}

		// Prepare message
		atomic
		{
			trpkt->tinaSelect = tinaSelect;
			trpkt->tct = tct;
			trpkt->depth = curdepth;
		}

		dbg("SRTreeC" , "Sending RoutingMsg... \n");

		// Enqueue
		enqueueDone=call RoutingSendQueue.enqueue(tmp);
		
		if( enqueueDone==SUCCESS)
		{
			// Post send of RoutingMsg
			if (call RoutingSendQueue.size()==1)
			{
				dbg("SRTreeC", "SendTask() posted!!\n");
				post sendRoutingTask();
			}
			dbg("SRTreeC","RoutingMsg enqueued successfully in SendingQueue!!!\n");
		}
		else
		{
			// error
			dbg("SRTreeC","RoutingMsg failed to be enqueued in SendingQueue!!!");
		}		
	}
	

///////////////////////
	event void RoutingAMSend.sendDone(message_t * msg , error_t err)
	{
		dbg("SRTreeC" , "Package sent %s \n", (err==SUCCESS)?"True":"False");

		if(!(call RoutingSendQueue.empty()))
		{
			// error - post again
			post sendRoutingTask();
		}		
	}


//////////////////////////////
	event message_t* RoutingReceive.receive( message_t * msg , void * payload, uint8_t len)
	{
		error_t enqueueDone;
		message_t tmp;
		uint16_t msource;
		
		// find message source
		msource = call RoutingAMPacket.source(msg);
		
		dbg("SRTreeC", "### RoutingReceive.receive() start ##### \n");
		dbg("SRTreeC", "Something received!!!  from %u \n", msource);
		
		// save message on temp var
		atomic
		{
			memcpy(&tmp,msg,sizeof(message_t));
		}
		// enqueue message
		enqueueDone=call RoutingReceiveQueue.enqueue(tmp);
		
		if(enqueueDone == SUCCESS)
		{
			// Post receive task
			post receiveRoutingTask();
		}
		else
		{
			// error
			dbg("SRTreeC","RoutingMsg enqueue failed!!! \n");
		}

		dbg("SRTreeC", "### RoutingReceive.receive() end ##### \n");
		return msg;
	}

/////////////////
	event void RoundTimer.fired()
	{
		roundCounter++;

		// Change round and print
		if (TOS_NODE_ID == 0)
		{
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
		void* measpkt;
		uint8_t query8bit, i;
		uint16_t query16bit;
		float avg;
		bool TinaPass = FALSE;



		// SendMeasTimer fires on round 1
		if (!FinishedRouting)
		{
			dbg("RoutingMsg", "FinishedRouting!\n");
			FinishedRouting = TRUE;	// Activate flag

			// Start seding measurements every epoch on 200ms window depending on depth (LIFO)
			// Removes simulation's boot time on round 1
			// Each node is shifted (Node 0 sends final result 200ms before epoch)
			// Also uses an offset of NODE_ID*3 to reduce conflicts on nodes being in the same depth
			call SendMeasTimer.startPeriodicAt(((-(BOOT_TIME)-((curdepth+1)*TIMER_FAST_PERIOD))+(TOS_NODE_ID*3)), TIMER_PERIOD_MILLI);
		}
		// SemdMeasTimer fires on round 2+
		else
		{
			dbg("Measurements", "NodeID = %d curdepth= %d\n", TOS_NODE_ID, curdepth);

			// if node is 0, we just search for the final result
			if (TOS_NODE_ID != 0)
			{
				dbg("Measurements", "Starting Data transmission to parent!\n");
			}
			
			dbg("SRTreeC", "SendMeasTimer fired!\n");

			// Assign random measurement(0..50) on node
			measurement = (call Random.rand16())%50;
			dbg("Measurements", "measurement is: %d\n", measurement);

			// error
			if(call MeasSendQueue.full())
			{
				dbg("SRTreeC", "MeasSendQueue full!\n");
				return;
			}

			if (tinaSelect == SUM)
			{
				measpkt = (OneMeas16bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas16bit)));
			}
			else
			{
				measpkt = (OneMeas8bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas8bit)));
			}

			// get payload for measpkt
			
			// error
			if(measpkt==NULL)
			{
				dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
				return;
			}

			// Count node's values to send to parent
			atomic
			{

				if (tinaSelect == SUM)
				{
					query16bit = measurement;
					for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
					{
						dbg("Measurements" , "ChildID: %d has sum: %d\n", children[i].childID, children[i].sum);

						query16bit += children[i].sum;
					}
					
					dbg("Measurements" , "Node's query is: %d\n", query16bit);
				}
				else if (tinaSelect == MAX)
				{
					query8bit = measurement;
					for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
					{
						dbg("Measurements" , "ChildID: %d has max: %d\n", children[i].childID, children[i].max);

						query8bit = (query8bit > children[i].max) ? query8bit : children[i].max;
					}

					dbg("Measurements" , "Node's query is: %d\n", query8bit);
				}
				else if (tinaSelect == MIN)
				{
					query8bit = measurement;
					for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
					{
						dbg("Measurements" , "ChildID: %d has min: %d\n", children[i].childID, children[i].min);

						query8bit = (query8bit < children[i].min) ? query8bit : children[i].min;
					}

					dbg("Measurements" , "Node's query is: %d\n", query8bit);
				}
				else
				{
					query8bit = 1;
					for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
					{
						dbg("Measurements" , "ChildID: %d has count: %d\n", children[i].childID, children[i].count);

						query8bit += children[i].count;
					}

					dbg("Measurements" , "Node's query is: %d\n", query8bit);
				}
			}

			if (tinaSelect == SUM)
			{
				if (roundCounter == 1 || query16bit > previousQuery16bit + ((float) tct / 100) * previousQuery16bit || query16bit < previousQuery16bit - ((float) tct / 100) * previousQuery16bit)
				{
					TinaPass = TRUE;
					dbg("Tina", "Measurement passes tct! Previous query: %d, Now sent: %d\n", previousQuery16bit, query16bit);
				}
				else
				{
					dbg("Tina", "Measurement doesn't pass tct! Previous query: %d, Now measured: %d\n", previousQuery16bit, query16bit);
				}
			}
			else
			{
				if (roundCounter == 1 || query8bit > previousQuery8bit + ((float) tct / 100) * previousQuery8bit || query8bit < previousQuery8bit - ((float) tct / 100) * previousQuery8bit)
				{
					dbg("Tina", "Measurement passes tct! Previous query: %d, Now sent: %d\n", previousQuery8bit, query8bit);
					TinaPass = TRUE;
				}
				else
				{
					dbg("Tina", "Measurement doesn't pass tct! Previous query: %d, Now measured: %d\n", previousQuery8bit, query8bit);
				}
			}


			// root node - Print final results
			if (TOS_NODE_ID == 0)
			{
				if (tinaSelect == SUM)
				{
					dbg("Measurements", "\n");
					dbg("Measurements" , "FINAL RESULTS: %d\n", query16bit);
					dbg("Measurements", "\n");
				}
				else
				{
					dbg("Measurements", "\n");
					dbg("Measurements" , "FINAL RESULTS: %d\n", query8bit);
					dbg("Measurements", "\n");
				}
			}
			else if (TinaPass)
			{
				// Prepare message
				atomic
				{
					if (tinaSelect == SUM)
					{
						previousQuery16bit = query16bit;
						((OneMeas16bit*) measpkt)->measurement = query16bit;
						call MeasAMPacket.setDestination(&tmp, parentID);
						call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas16bit));
					}
					else
					{
						previousQuery8bit = query8bit;
						((OneMeas8bit*) measpkt)->measurement = query8bit;
						call MeasAMPacket.setDestination(&tmp, parentID);
						call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas8bit));
					}
				}
				
				dbg("SRTreeC" , "Sending MeasMsg... \n");
				
				// Enqueue
				enqueueDone=call MeasSendQueue.enqueue(tmp);
		
				if (enqueueDone == SUCCESS)
				{
					if (call MeasSendQueue.size() == 1)
					{
						// Post send
						dbg("SRTreeC", "SendMeasTask() posted!!\n");
						post sendMeasTask();
					}
					
					dbg("SRTreeC","MeasMsg enqueued successfully in MeasSendQueue!!!\n");
				}
				else
				{
					// error
					dbg("SRTreeC","MeasMsg failed to be enqueued in MeasSendQueue!!!");
				}		
			}
			else
			{
				dbg("Tina", "Doesn't send\n");
			}
		}
	}


/////////////////////////////	
	event void MeasAMSend.sendDone(message_t *msendDonesg , error_t err)
	{
		// Check if message is sent successfully
		dbg("SRTreeC", "A Measure package sent... %s \n",(err==SUCCESS)?"True":"False");		
		
		// error - post send again
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
		
		// Find message source
		msource = call MeasAMPacket.source(msg);
		
		dbg("SRTreeC", "### MeasReceive.receive() start ##### \n");
		dbg("SRTreeC", "Some measurement received!!!  from %u \n", msource);

		// save message on temp var
		atomic
		{
			memcpy(&tmp,msg,sizeof(message_t));
		}
		// enqueue message
		enqueueDone=call MeasReceiveQueue.enqueue(tmp);

		if( enqueueDone== SUCCESS)
		{
			// Post receive task
			post receiveMeasTask();
		}
		else
		{
			// error
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
		
		// error
		if (call RoutingSendQueue.empty())
		{
			dbg("SRTreeC","sendRoutingTask(): Q is empty!\n");
			return;
		}
		
		// dequeue message
		radioRoutingSendPkt = call RoutingSendQueue.dequeue();

		// send RoutingMsg
		sendDone=call RoutingAMSend.send(AM_BROADCAST_ADDR,&radioRoutingSendPkt,sizeof(TinaRoutingMsg));
		
		if ( sendDone== SUCCESS)
		{
			dbg("SRTreeC","sendRoutingTask(): Send returned success!!!\n");
		}
		else
		{
			// error
			dbg("SRTreeC","send failed!!!\n");
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
		uint16_t msource;
		
		// dequeue message
		radioRoutingRecPkt= call RoutingReceiveQueue.dequeue();
		
		// find payload length
		len = call RoutingPacket.payloadLength(&radioRoutingRecPkt);

		// Find message source
		msource = call RoutingAMPacket.source(&radioRoutingRecPkt);
		
		dbg("SRTreeC","ReceiveRoutingTask(): len=%u \n",len);
		
		// Correct message
		if(len == sizeof(TinaRoutingMsg))
		{
			// Get message
			TinaRoutingMsg * trpkt = (TinaRoutingMsg*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
			
			dbg("SRTreeC" , "receiveRoutingTask(): source= %d , depth= %d \n", msource , trpkt->depth);

			// Node doesn't have a parent
			if ( (parentID<0)||(parentID>=65535))
			{
				// Assign source as parent
				parentID = msource;
				curdepth = trpkt->depth + 1;
				tinaSelect = trpkt->tinaSelect;
				tct = trpkt->tct;
				dbg("RoutingMsg" , "New parent for NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
				dbg("Tina", "tinaSelect= %d , tct=%d\n", tinaSelect, tct);
				// Forward routing message to find new children 
				call RoutingMsgTimer.startOneShot(TIMER_FAST_PERIOD);
			}
			else
			{
				// Node already has parent
				dbg("SRTreeC" , "NodeID= %d : Already has a parent: curdepth= %d, parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
			}
		}
		else
		{
			// error
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
		
		// error
		if (call MeasSendQueue.empty())
		{
			dbg("SRTreeC","sendMeasTask(): Q is empty!\n");
			return;
		}
		
		// dequeue message
		radioMeasSendPkt = call MeasSendQueue.dequeue();
		
		// get payload length
		mlen=call MeasPacket.payloadLength(&radioMeasSendPkt);
				
		// set destination
		mdest= call MeasAMPacket.destination(&radioMeasSendPkt);
		
		// send message
		sendDone = call MeasAMSend.send(mdest,&radioMeasSendPkt, mlen);
		
		if ( sendDone == SUCCESS)
		{
			dbg("SRTreeC","sendMeasTask(): Send measure returned success!!!\n");
		}
		else
		{
			// error
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
		void* mr;
		
		// dequeue message
		radioMeasRecPkt= call MeasReceiveQueue.dequeue();
		
		// find payload length
		len= call MeasPacket.payloadLength(&radioMeasRecPkt);

		// find source (child)
		msource = call MeasAMPacket.source(&radioMeasRecPkt);
		
		dbg("SRTreeC","receiveMeasTask(): len=%u \n",len);


		if (tinaSelect == SUM)
		{
			mr = (OneMeas16bit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));
		}
		else
		{
			mr = (OneMeas8bit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));
		}
		
		dbg("SRTreeC" , "MeasMsg received from %d !!! \n", msource);

		// Update children table with received values
		for (i=0; i < MAX_CHILDREN; i++)
		{
			// Child already on table or new child
			if (children[i].childID == msource || children[i].childID == 0)
			{
				// new child - assign it on table
				if (children[i].childID==0)
				{
					children[i].childID = msource;
				}
				if (tinaSelect == SUM)
				{
					children[i].sum = ((OneMeas16bit*) mr)->measurement;
				}
				else if (tinaSelect == MAX)
				{
					children[i].max = ((OneMeas8bit*) mr)->measurement;
				}
				else if (tinaSelect == MIN)
				{
					children[i].min = ((OneMeas8bit*) mr)->measurement;
				}
				else
				{
					children[i].count = ((OneMeas8bit*) mr)->measurement;
				}

				dbg("Measurements" , "Received from childID: %d values - sum:%d, count: %d, max: %d\n", children[i].childID, children[i].sum, children[i].count, children[i].max);
				// Child is assigned on the table - stop itteration
				break;
			}
		}
	}
}

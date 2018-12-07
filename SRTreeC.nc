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
	uint16_t previousQuery;

	uint8_t select[MAX_QUERIES];
	uint8_t tct;
	uint8_t mode;			// Extend is 0, Tina is 1
	uint8_t num;

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
		uint8_t i;
		uint16_t seedNum;
		FILE *f;

		/////// arxikopoiisi radio
		call RadioControl.start();

		roundCounter = 0;

		for (i = 0; i < MAX_QUERIES; i++)
		{
			select[i]=0;
		}
		
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

			mode = (call Random.rand16())%2;
			dbg("Boot", "MODE(0=extended - 1=Tina): %d\n", mode);
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
				children[i].sumsq = 0;

				dbg("Tests", "Init child: %d, childID: %d, sum: %d, count: %d, max: %d, min: %d, sumsq: %d\n", i, children[i].childID, children[i].sum, children[i].count, children[i].max, children[i].min, children[i].sumsq);
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
		void* rpkt;
		uint8_t i;
		
		dbg("SRTreeC", "RoutingMsgTimer fired!\n");

		roundCounter+=1;

		if (TOS_NODE_ID==0)
		{
			if (mode == 1) 
			{
				select[0] = ((call Random.rand16())%4) + 1;
				tct = (call Random.rand16())%51;
				dbg("Tina", "Query selected for TINA is: %d with tct: %d\n", select[0], tct);
			}
			else
			{
				num = ((call Random.rand16())%2) + 1;
				dbg("Extend", "We have %d queries!\n", num);
				for (i=0; i < num; i++)
				{
					select[i] = ((call Random.rand16())%6) + 1;
					while (select[1] == select[0])
					{
						select[1] = ((call Random.rand16())%6) + 1;
					}
				
					dbg("Extend", "query %d is: %d\n", (i+1), select[i]);
				}
			}

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
		
		// get payload for rpkt
		if (mode == 1)
		{
			rpkt = (TinaRoutingMsg*) (call RoutingPacket.getPayload(&tmp, sizeof(TinaRoutingMsg)));

			if(rpkt==NULL)
			{
				dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
				return;
			}

			atomic
			{
				((TinaRoutingMsg*)rpkt)->mode = mode;
				((TinaRoutingMsg*)rpkt)->select = select[0];
				((TinaRoutingMsg*)rpkt)->tct = tct;
				((TinaRoutingMsg*)rpkt)->depth = curdepth;
			}
		}
		else if (num == 1)
		{
			rpkt = (extendRoutingMsg1Q*) (call RoutingPacket.getPayload(&tmp, sizeof(extendRoutingMsg1Q)));

			if(rpkt==NULL)
			{
				dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
				return;
			}

			atomic
			{
				((extendRoutingMsg1Q*)rpkt)->mode = mode;
				((extendRoutingMsg1Q*)rpkt)->select = select[0];
				((extendRoutingMsg1Q*)rpkt)->depth = curdepth;
			}
		}
		else
		{
			rpkt = (extendRoutingMsg2Q*) (call RoutingPacket.getPayload(&tmp, sizeof(extendRoutingMsg2Q)));

			if(rpkt==NULL)
			{
				dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
				return;
			}

			atomic
			{
				((extendRoutingMsg2Q*)rpkt)->mode = mode;
				((extendRoutingMsg2Q*)rpkt)->select[0] = select[0];
				((extendRoutingMsg2Q*)rpkt)->select[1] = select[1];
				((extendRoutingMsg2Q*)rpkt)->depth = curdepth;
			}
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
		uint8_t i;
		uint16_t query;
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


			if (mode == 1 || (mode == 0 && select[1] == 0))
			{
				if (select[0] == SUM)
				{
					measpkt = (OneMeas16bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas16bit)));
				}
				else if (select[0] == AVG)
				{
					measpkt = (TwoMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeasMixedbit)));
				}
				else if (select[0] == VAR)
				{
					measpkt = (VarMeasSimple*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasSimple)));
				}
				else
				{
					measpkt = (OneMeas8bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas8bit)));
				}
			}
			else 	// mode==0 and select[1]!=0
			{
				if ((select[0] == MAX || select[0] == MIN || select[0] == COUNT) && (select[1] == MAX || select[1] == MIN || select[1] == COUNT))
				{
					measpkt = (TwoMeas8bit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeas8bit)));
				}
				else if ((select[0] == SUM && select[1] != VAR)  || (select[1] == SUM && select[0] != VAR) || (select[0] == AVG && select[1] == COUNT)  || (select[1] == AVG && select[0] == COUNT))
				{
					measpkt = (TwoMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeasMixedbit)));
				}
				else if ((select[0] == AVG && (select[1] == MIN || select[1] == MAX)) || (select[1] == AVG && (select[0] == MIN || select[0] == MAX)))
				{
					measpkt = (ThreeMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(ThreeMeasMixedbit)));
				}
				else if ((select[0] == VAR && (select[1] != MIN && select[1] != MAX)) || (select[1] == VAR && (select[0] != MIN && select[0] != MAX)))
				{
					measpkt = (VarMeasSimple*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasSimple)));
				}
				else
				{
					measpkt = (VarMeasDouble*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasDouble)));
				}
			}
		
			// error
			if(measpkt==NULL)
			{
				dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
				return;
			}

			// Count node's values to send to parent
			atomic
			{
				query = measurement;

				if (tinaSelect == SUM)
				{
					
					for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
					{
						dbg("Measurements" , "ChildID: %d has sum: %d\n", children[i].childID, children[i].sum);

						query += children[i].sum;
					}
					
					dbg("Measurements" , "Node's query is: %d\n", query);
				}
				else if (tinaSelect == MAX)
				{
					for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
					{
						dbg("Measurements" , "ChildID: %d has max: %d\n", children[i].childID, children[i].max);

						query = (query > children[i].max) ? query : children[i].max;
					}

					dbg("Measurements" , "Node's query is: %d\n", query);
				}
				else if (tinaSelect == MIN)
				{
					for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
					{
						dbg("Measurements" , "ChildID: %d has min: %d\n", children[i].childID, children[i].min);

						query = (query < children[i].min) ? query : children[i].min;
					}

					dbg("Measurements" , "Node's query is: %d\n", query);
				}
				else
				{
					query = 1;
					for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
					{
						dbg("Measurements" , "ChildID: %d has count: %d\n", children[i].childID, children[i].count);

						query += children[i].count;
					}

					dbg("Measurements" , "Node's query is: %d\n", query);
				}
			}


			if (roundCounter == 1 || query > previousQuery + ((float) tct / 100) * previousQuery || query < previousQuery - ((float) tct / 100) * previousQuery)
			{
				TinaPass = TRUE;
				dbg("Tina", "Measurement passes tct! Previous query: %d, Now sent: %d\n", previousQuery, query);
			}
			else
			{
				dbg("Tina", "Measurement doesn't pass tct! Previous query: %d, Now measured: %d\n", previousQuery, query);
			}


			// root node - Print final results
			if (TOS_NODE_ID == 0)
			{
				dbg("Measurements", "\n");
				dbg("Measurements" , "FINAL RESULTS: %d\n", query);
				dbg("Measurements", "\n");
			}
			else if (TinaPass)
			{
				// Prepare message
				atomic
				{
					previousQuery = query;
					call MeasAMPacket.setDestination(&tmp, parentID);

					if (tinaSelect == SUM)
					{
						((OneMeas16bit*) measpkt)->measurement = query;
						call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas16bit));
					}
					else
					{
						((OneMeas8bit*) measpkt)->measurement = query;
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
		if(len == sizeof(TinaRoutingMsg) || len == sizeof(extendRoutingMsg1Q) || len == sizeof(extendRoutingMsg2Q))
		{			
			// Node doesn't have a parent
			if ( (parentID<0)||(parentID>=65535))
			{
				if (len == sizeof(TinaRoutingMsg))
				{
					TinaRoutingMsg * trpkt = (TinaRoutingMsg*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
					dbg("SRTreeC" , "receiveRoutingTask(): source= %d , depth= %d \n", msource , trpkt->depth);

					// Assign source as parent
					parentID = msource;
					mode = trpkt->mode;
					curdepth = trpkt->depth + 1;
					select[0] = trpkt->select;
					tct = trpkt->tct;

					dbg("RoutingMsg" , "New parent for NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
					dbg("Tina", "tinaSelect= %d , tct=%d\n", select[0], tct);
				}
				else if (len == sizeof(extendRoutingMsg1Q))
				{
					extendRoutingMsg1Q* e1rpkt = (extendRoutingMsg1Q*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
					dbg("SRTreeC" , "receiveRoutingTask(): source= %d , depth= %d \n", msource , e1rpkt->depth);

					// Assign source as parent
					parentID = msource;
					mode = e1rpkt->mode;
					curdepth = e1rpkt->depth + 1;
					select[0] = e1rpkt->select;

					dbg("RoutingMsg" , "New parent for NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
					dbg("Extend", "ExtendSelect= %d\n", select[0]);
				}
				else
				{
					extendRoutingMsg2Q* e2rpkt = (extendRoutingMsg2Q*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
					dbg("SRTreeC" , "receiveRoutingTask(): source= %d , depth= %d \n", msource , e2rpkt->depth);

					// Assign source as parent
					parentID = msource;
					mode = e2rpkt->mode;
					curdepth = e2rpkt->depth + 1;
					select[0] = e2rpkt->select[0];
					select[1] = e2rpkt->select[1];

					dbg("RoutingMsg" , "New parent for NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
					dbg("Extend", "ExtendSelect1= %d, ExtendSelect2= %d\n", select[0], select[1]);
				}
	
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

				dbg("Measurements" , "Received from childID: %d values - sum:%d, count: %d, max: %d, min: %d\n", children[i].childID, children[i].sum, children[i].count, children[i].max, children[i].min);
				// Child is assigned on the table - stop itteration
				break;
			}
		}
	}
}

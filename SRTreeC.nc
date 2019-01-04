#include "SimpleRoutingTree.h"

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
	// Counter holding current round
	uint16_t  roundCounter;
	
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

	// Array holding the queries executed
	uint8_t select[MAX_QUERIES];
	// tct for Tina (percentage)
	uint8_t tct;
	// Query mode: Extended TAG->0, Tina->1
	uint8_t mode;

	// Array holding children values received
	ChildInfo children[MAX_CHILDREN];
	
	// Tasks
	task void sendRoutingTask();
	task void receiveRoutingTask();
	task void sendMeasTask();
	task void receiveMeasTask();

	// Functions
	uint32_t calculateQuery(uint8_t op, uint8_t nodeMeas);


////////////////////	
	event void Boot.booted()
	{
		uint8_t i;
		uint16_t seedNum;
		FILE *f;

		// Start radio
		call RadioControl.start();

		// Initialisation
		roundCounter = 0;

		for (i = 0; i < MAX_QUERIES; i++)
		{
			select[i]=0;
		}
		
		// Change random's seed to seperate it from TOS_NODE_ID
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

			// Assign random query mode (Extended(0) or Tina(1))
			mode = (call Random.rand16())%2;
			dbg("Boot", "\n\nMODE(extended -> 0, Tina -> 1	): %d\n\n", mode);
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

			// Children initialisation (childID==0 means no child)
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

		// Round 1
		roundCounter+=1;

		if (TOS_NODE_ID==0)
		{
			// num holding number of queries(1 or 2 - Only on Extended TAG)
			uint8_t num;

			// If TINA
			if (mode == 1) 
			{
				// Random query
				select[0] = ((call Random.rand16())%4) + 1;
				// Random tct
				tct = (call Random.rand16())%51;
				dbg("Tina", "Query selected for TINA is: %d with tct: %d\n", select[0], tct);
			}
			// If Extended TAG
			else
			{
				// Random number of queries
				num = ((call Random.rand16())%2) + 1;
				dbg("Extend", "We have %d queries!\n", num);

				// Assign randome query/queries
				for (i=0; i < num; i++)
				{
					select[i] = ((call Random.rand16())%6) + 1;
					// If num==2 the second query must be different than the first
					while (select[1] == select[0])
					{
						select[1] =((call Random.rand16())%6) + 1;
					}
				
					dbg("Extend", "Query %d is: %d\n", (i+1), select[i]);
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
		
		// If we have 4 routing fields(Tina || Extended TAG with num==2)
		if (mode == 1 || (mode == 0 && select[1] != 0))
		{
			// Get payload for Routing4field
			rpkt = (Routing4field*) (call RoutingPacket.getPayload(&tmp, sizeof(Routing4field)));

			dbg("SRTreeC","Creating Routing4field...\n");

			// error
			if(rpkt==NULL)
			{
				dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
				return;
			}

			// Assign values
			atomic
			{
				((Routing4field*)rpkt)->mode = mode;
				((Routing4field*)rpkt)->select = select[0];
				((Routing4field*)rpkt)->depth = curdepth;

				// If Tina, use select2ortct to store tct
				if (mode == 1)
				{
					((Routing4field*)rpkt)->select2ortct = tct;
				}
				// If Extended TAG with num==2, use select2ortct to store the second query
				else
				{
					((Routing4field*)rpkt)->select2ortct = select[1];
				}
			}
		}
		// Extended TAG with num==1
		else
		{
			// Get payload for Routing3field
			rpkt = (Routing3field*) (call RoutingPacket.getPayload(&tmp, sizeof(Routing3field)));
			
			dbg("SRTreeC","Creating Routing3field...\n");

			// error
			if(rpkt==NULL)
			{
				dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
				return;
			}

			// Assign values
			atomic
			{
				((Routing3field*)rpkt)->mode = mode;
				((Routing3field*)rpkt)->select = select[0];
				((Routing3field*)rpkt)->depth = curdepth;
			}
		}
		
		dbg("SRTreeC" , "Sending RoutingMsg... \n");

		// Enqueue
		enqueueDone=call RoutingSendQueue.enqueue(tmp);
		
		if( enqueueDone==SUCCESS)
		{
			// Post send of Routing message
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
		
		// Find message source
		msource = call RoutingAMPacket.source(msg);
		
		dbg("SRTreeC", "### RoutingReceive.receive() start ##### \n");
		dbg("SRTreeC", "Something received!!!  from %u \n", msource);
		
		// Save message on temp var
		atomic
		{
			memcpy(&tmp,msg,sizeof(message_t));
		}
		// Enqueue message
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
		OneMeas8bit* measpkt;
		uint8_t test;

		// SendMeasTimer fires on round 1
		if (!FinishedRouting)
		{
			dbg("RoutingMsg", "FinishedRouting!\n");
			FinishedRouting = TRUE;	// Activate flag

			// Start sending measurements every epoch on 200ms window depending on depth (LIFO)
			// Removes simulation's boot time on round 1
			// Each node is shifted (Node 0 sends final result 200ms before epoch)
			// Also uses an offset of NODE_ID*3 to reduce conflicts on nodes being in the same depth
			call SendMeasTimer.startPeriodicAt(((-(BOOT_TIME)-((curdepth+1)*TIMER_FAST_PERIOD))+(TOS_NODE_ID*3)), TIMER_PERIOD_MILLI);
		}
		// SemdMeasTimer fires on round 2+
		else
		{
			dbg("Measurements", "NodeID = %d curdepth= %d\n", TOS_NODE_ID, curdepth);

			// if node is 0, we just print the final result
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
	
			// Create the message holding the measurement
			call MeasAMPacket.setDestination(&tmp, parentID);
			
			measpkt = (OneMeas8bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas8bit)));
			call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas8bit));
			
			// error
			if(measpkt==NULL)
			{
				dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
				return;
			}

			measpkt->measurement = measurement;
			
			
			dbg("SRTreeC" , "Sending MeasMsg... \n");
			
			// Enqueue
			enqueueDone=call MeasSendQueue.enqueue(tmp);

			if (enqueueDone == SUCCESS)
			{
				if (call MeasSendQueue.size() == 1)
				{

					// Post send
					post sendMeasTask();
				}
				
				dbg("SRTreeC","MeasMsg enqueued successfully in MeasSendQueue!!!\n");
			}
			else
			{
				// error
				dbg("SRTreeC","MeasMsg failed to be enqueued in MeasSendQueue!!!\n");
			}		
		}
	}



/////////////////////////////	
	event void MeasAMSend.sendDone(message_t* msg , error_t err)
	{
		// Check if message is sent successfully
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
		
		// Find message source
		msource = call MeasAMPacket.source(msg);
		
		dbg("Measurements", "Measurement received from: %d\n", msource);
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
	

////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////
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

		// Send Routing4field message (if Tina || Extended TAG with 2 queries)
		if (mode == 1 || (mode == 0 && select[1] != 0))
		{
			sendDone=call RoutingAMSend.send(AM_BROADCAST_ADDR,&radioRoutingSendPkt,sizeof(Routing4field));
		}
		// Send Routing3field message (if Extended TAG with 1 query)
		else
		{
			sendDone=call RoutingAMSend.send(AM_BROADCAST_ADDR,&radioRoutingSendPkt,sizeof(Routing3field));
		}
		
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
	///////////////////////////////////////////////////////////////////
	//////////////////////////////////////////////////////////////////
	task void receiveRoutingTask()
	{
		uint8_t len;
		message_t radioRoutingRecPkt;
		uint16_t msource;
		
		// dequeue message
		radioRoutingRecPkt= call RoutingReceiveQueue.dequeue();
		
		// find payload length
		len = call RoutingPacket.payloadLength(&radioRoutingRecPkt);

		dbg("Tests", "len: %d, sizeof(Routing4field): %d, sizeof(Routing3field): %d\n", len, sizeof(Routing4field), sizeof(Routing3field));
		// Find message source
		msource = call RoutingAMPacket.source(&radioRoutingRecPkt);
		
		dbg("SRTreeC","ReceiveRoutingTask(): len=%u \n",len);

		// Correct message
		if(len == sizeof(Routing4field) || len == sizeof(Routing3field))
		{			
			// Node doesn't have a parent
			if ( (parentID<0)||(parentID>=65535))
			{
				// Tina || Extended TAG with 2 queries
				if (len == sizeof(Routing4field))
				{
					// Get packet's payload
					Routing4field* rpkt = (Routing4field*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
					dbg("SRTreeC" , "receiveRoutingTask(): source= %d , depth= %d \n", msource , rpkt->depth);


					// Assign values received
					parentID = msource;
					mode = rpkt->mode;
					curdepth = rpkt->depth + 1;
					select[0] = rpkt->select;
					
					dbg("RoutingMsg" , "New parent for NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);

					// If Tina, save select2ortct as tct
					if (mode == 1)
					{
						tct = rpkt->select2ortct;
						dbg("Tina", "tinaSelect= %d , tct=%d\n", select[0], tct);
					}
					// If Extended TAG with 2 queries, save select2ortct as second query
					else
					{
						select[1] = rpkt->select2ortct;
						dbg("Extend", "ExtendSelect1= %d, ExtendSelect2= %d\n", select[0], select[1]);
					}
				}
				// Extened TAG with 1 query
				else
				{
					// Get packet's payload
					Routing3field* rpkt = (Routing3field*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
					dbg("SRTreeC" , "receiveRoutingTask(): source= %d , depth= %d \n", msource , rpkt->depth);

					// Assign values received
					parentID = msource;
					mode = rpkt->mode;
					curdepth = rpkt->depth + 1;
					select[0] = rpkt->select;

					dbg("RoutingMsg" , "New parent for NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);
					dbg("Extend", "ExtendSelect= %d\n", select[0]);
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
		uint8_t mlen, nodeMeas, i;//, skip;
		error_t sendDone;
		uint16_t mdest;
		OneMeas8bit* mpayload;
		bool TinaPass = FALSE;
		message_t tmp;

		
		// error
		if (call MeasSendQueue.empty())
		{
			dbg("SRTreeC","sendMeasTask(): Q is empty!\n");
			return;
		}
		
		// Dequeue message
		radioMeasSendPkt = call MeasSendQueue.dequeue();

		// Get payload's length
		mlen=call MeasPacket.payloadLength(&radioMeasSendPkt);
		
		// Get payload
		mpayload= call MeasPacket.getPayload(&radioMeasSendPkt,mlen);

		// error
		if(mlen!= sizeof(OneMeas8bit))
		{
			dbg("SRTreeC", "\t\t sendMeasTask(): Unknown message!!\n");
			return;
		}

		// Save measurement
		nodeMeas = mpayload->measurement;

		// Tina || Extended TAG with 1 query
		if (mode == 1 || (mode == 0 && select[1] == 0))	
		{
			// Query: SUM
			if (select[0] == SUM)
			{
				uint16_t query;
				OneMeas16bit* measpkt;

				// We send the message on a OneMeas16bit struct (One 16-bit number)
				call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas16bit));
				measpkt = (OneMeas16bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas16bit)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}

				// Calculate SUM
				query = calculateQuery(SUM, nodeMeas);

				// Node 0 - print results
				if (TOS_NODE_ID == 0)
				{
					dbg("Measurements", "\n");
					dbg("Measurements" , "FINAL RESULTS: SUM: %d\n", query);
					dbg("Measurements", "\n");
				}
				else if (mode == 1)		// Tina
				{
					// If query result is outside tct or we are on first round - send message
					if (roundCounter == 1 || query > previousQuery + ((float) tct / 100) * previousQuery || query < previousQuery - ((float) tct / 100) * previousQuery)
					{
						// Set flag true
						TinaPass = TRUE;
						dbg("Tina", "Measurement passes tct! Previous query: %d, Now sent: %d\n", previousQuery, query);
					}
					// Query result is within tct - don't send message
					else
					{
						dbg("Tina", "Measurement doesn't pass tct! Previous query: %d, Now measured: %d\n", previousQuery, query);
					}

					// Query result passes tct - send message
					if (TinaPass)
					{
						// Prepare message
						atomic
						{
							// Save query result as last query sent
							previousQuery = query;
							call MeasAMPacket.setDestination(&tmp, parentID);

							((OneMeas16bit*) measpkt)->measurement = query;
						}
					}
				}
				else 	// Extended TAG
				{
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);
						((OneMeas16bit*) measpkt)->measurement = query;
					}
				}
			}
			// Query: AVG (Only on Extended TAG)
			else if (select[0] == AVG)
			{
				uint16_t sum;
				uint8_t count;
				TwoMeasMixedbit* measpkt;

				// We send the message on a TwoMeasMixedbit struct (One 16-bit and one 8-bit number)
				call MeasPacket.setPayloadLength(&tmp,sizeof(TwoMeasMixedbit));
				measpkt = (TwoMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeasMixedbit)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}

				// Calculate queries
				sum = calculateQuery(SUM, nodeMeas);
				count = calculateQuery(COUNT, nodeMeas);

				// Node 0 - print results
				if (TOS_NODE_ID == 0)
				{
					dbg("Measurements", "\n");
					dbg("Measurements" , "FINAL RESULTS: AVG: %.2f\n", (sum / (float) count));
					dbg("Measurements", "\n");
				}
				else
				{
					// Prepare message
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);

						((TwoMeasMixedbit*) measpkt)->measurement16bit = sum;
						((TwoMeasMixedbit*) measpkt)->measurement8bit = count;
					}
				}
			}
			// Query: VAR (Only on Extended TAG)
			else if (select[0] == VAR)
			{
				uint32_t sumsq;
				uint16_t sum;
				uint8_t count;
				VarMeasSimple* measpkt;

				// We send the message on a VarMeasSimple struct (One 32-bit, one 16-bit and one 8-bit number)
				call MeasPacket.setPayloadLength(&tmp,sizeof(VarMeasSimple));
				measpkt = (VarMeasSimple*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasSimple)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}

				// Calculate queries
				sumsq = calculateQuery(SUMSQ, nodeMeas);
				sum = calculateQuery(SUM, nodeMeas);
				count = calculateQuery(COUNT, nodeMeas);

				// Node 0 - print results
				if (TOS_NODE_ID == 0)
				{
					dbg("Measurements", "\n");
					dbg("Measurements" , "FINAL RESULTS: VAR: %.2f\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))));
					dbg("Measurements", "\n");
				}
				else
				{
					// Prepare message
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);

						((VarMeasSimple*) measpkt)->measurement32bit = sumsq;
						((VarMeasSimple*) measpkt)->measurement16bit = sum;
						((VarMeasSimple*) measpkt)->measurement8bit = count;
					}
				}
			}
			// Queries: MAX || MIN || COUNT
			else
			{
				uint8_t query;
				OneMeas8bit* measpkt;

				// We send the message on a OneMeas8bit struct (One 8-bit number)
				call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas8bit));
				measpkt = (OneMeas8bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas8bit)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}

				// If query: MAX
				if (select[0] == MAX)
				{
					// Calculate query
					query = calculateQuery(MAX, nodeMeas);

					// Node 0 - print results
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULT: MAX: %d\n", query);
						dbg("Measurements", "\n");
					}
				}
				// If query: MIN
				else if (select[0] == MIN)
				{
					// Node 0 - print results
					query = calculateQuery(MIN, nodeMeas);

					// Node 0 - print results
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULT: MIN: %d\n", query);
						dbg("Measurements", "\n");
					}
				}
				// If query: COUNT
				else
				{
					// Calculate query
					query = calculateQuery(COUNT, nodeMeas);

					// Node 0 - print results
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULT: COUNT: %d\n", query);
						dbg("Measurements", "\n");
					}
				}

				// TINA - Node!=0
				if (mode == 1 && TOS_NODE_ID != 0)
				{
					// If query result is outside tct or we are on first round - send message
					if (roundCounter == 1 || query > previousQuery + ((float) tct / 100) * previousQuery || query < previousQuery - ((float) tct / 100) * previousQuery)
					{
						// Set flag to true
						TinaPass = TRUE;
						dbg("Tina", "Measurement passes tct! Previous query: %d, Now sent: %d\n", previousQuery, query);
					}
					// Query result is inside tct - don't send message
					else
					{
						dbg("Tina", "Measurement doesn't pass tct! Previous query: %d, Now measured: %d\n", previousQuery, query);
					}

					// Query result passes tct - send message
					if (TinaPass)
					{
						// Prepare message
						atomic
						{
							// Save query result as last query sent
							previousQuery = query;
							call MeasAMPacket.setDestination(&tmp, parentID);

							((OneMeas8bit*) measpkt)->measurement = query;
						}
					}
				}
				// Extended TAG with 1 query
				else if (TOS_NODE_ID != 0)
				{
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);

						((OneMeas8bit*) measpkt)->measurement = query;
					}
				}
			}
		}
		else 	// Extended mode with 2 queries
		{
			// Queries: MAX-MIN || MAX-COUNT || MIN-COUNT
			if ((select[0] == MAX || select[0] == MIN || select[0] == COUNT) && (select[1] == MAX || select[1] == MIN || select[1] == COUNT))
			{
				uint8_t query[MAX_QUERIES], measurementQueries[MAX_QUERIES], curQuery;
				TwoMeas8bit* measpkt;

				curQuery = 0;		// curQuery holds the query we are currently on(0 or 1)

				// We send the message on a TwoMeas8bit struct (Two 8-bit numbers and one holding the type of queries)
				call MeasPacket.setPayloadLength(&tmp,sizeof(TwoMeas8bit));
				measpkt = (TwoMeas8bit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeas8bit)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}

				// One of the queries is MAX
				if (select[0] == MAX || select[1] == MAX)
				{
					// Calculate query on an 8-bit array holding the result and save the type of query
					query[curQuery] = calculateQuery(MAX, nodeMeas);
					measurementQueries[curQuery] = MAX;
					
					// Node 0 - print result
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements" , "FINAL RESULTS: MAX: %d\n", query[curQuery]);
					}

					// First query found
					curQuery++;
				}

				// One of the queries is MIN
				if (select[0] == MIN || select[1] == MIN)
				{
					// Calculate query on an 8-bit array holding the result and save the type of query
					query[curQuery] = calculateQuery(MIN, nodeMeas);
					measurementQueries[curQuery] = MIN;

					// Node 0 - print result
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements" , "FINAL RESULTS: MIN: %d\n", query[curQuery]);
					}

					// First query found
					curQuery++;
				}

				// One of the queries is COUNT
				if (select[0] == COUNT || select[1] == COUNT)
				{
					// Calculate query on an 8-bit array holding the result and save the type of query
					query[curQuery] = calculateQuery(COUNT, nodeMeas);
					measurementQueries[curQuery] = COUNT;

					// Node 0 - print result
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements" , "FINAL RESULTS: COUNT: %d\n", query[curQuery]);
					}

					// First query found
					curQuery++;
				}

				// Send measage
				if (TOS_NODE_ID != 0)
				{
					// Prepare message
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);

						((TwoMeas8bit*) measpkt)->measurement1 = query[0];
						((TwoMeas8bit*) measpkt)->measurement2 = query[1];
						((TwoMeas8bit*) measpkt)->measurementQueries[0] = measurementQueries[0];
						((TwoMeas8bit*) measpkt)->measurementQueries[1] = measurementQueries[1];
					}
				}
			}
			// Queries: SUM-MAX || SUM-MIN || SUM-COUNT || SUM-AVG || AVG-COUNT
			else if ((select[0] == SUM && select[1] != VAR)  || (select[1] == SUM && select[0] != VAR) || (select[0] == AVG && select[1] == COUNT)  || (select[1] == AVG && select[0] == COUNT))
			{
				uint16_t query16;
				uint8_t query8;
				TwoMeasMixedbit* measpkt;

				// We send the message on a TwoMeasMixedbit struct (One 16-bit number and one 8-bit number)
				call MeasPacket.setPayloadLength(&tmp,sizeof(TwoMeasMixedbit));
				measpkt = (TwoMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeasMixedbit)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}

				// Calculate query
				query16 = calculateQuery(SUM, nodeMeas);

				// One of the queries is AVG
				if (select[0] == AVG || select[1] == AVG)
				{
					// Calculate count
					query8 = calculateQuery(COUNT, nodeMeas);

					// Node 0 - print result
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");

						// The other query is SUM
						if (select[0] == SUM || select[1] == SUM)
						{
							dbg("Measurements" , "FINAL RESULTS: AVG: %.2f, SUM: %d\n", (query16 / (float) query8), query16);
						}
						// The other query is COUNT
						else
						{
							dbg("Measurements" , "FINAL RESULTS: AVG: %.2f, COUNT: %d\n", (query16 / (float) query8), query8);
						}
						dbg("Measurements", "\n");
					}
				}
				// One of the queries is SUM
				else
				{
					// The other query is MAX
					if (select[0] == MAX || select[1] == MAX)
					{
						// Calculate MAX
						query8 = calculateQuery(MAX, nodeMeas);
						
						// Node 0 - print results
						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULTS: SUM: %d, MAX: %d\n", query16, query8);
							dbg("Measurements", "\n");
						}
					}
					// The other query is MIN
					else if (select[0] == MIN || select[1] == MIN)
					{
						// Calculate MIN
						query8 = calculateQuery(MIN, nodeMeas);
						
						// Node 0 - print results
						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULTS: SUM: %d, MIN: %d\n", query16, query8);
							dbg("Measurements", "\n");
						}
					}
					// The other query is COUNT
					else
					{
						// Calculate COUNT
						query8 = calculateQuery(COUNT, nodeMeas);
						
						// Node 0 - print results
						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULTS: SUM: %d, COUNT: %d\n", query16, query8);
							dbg("Measurements", "\n");
						}
					}
				}

				// Send message
				if (TOS_NODE_ID != 0)
				{
					// Prepare message
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);

						((TwoMeasMixedbit*) measpkt)->measurement16bit = query16;
						((TwoMeasMixedbit*) measpkt)->measurement8bit = query8;
					}
				}
			}
			// Queries: AVG-MIN || AVG-MAX
			else if ((select[0] == AVG && (select[1] == MIN || select[1] == MAX)) || (select[1] == AVG && (select[0] == MIN || select[0] == MAX)))
			{
				uint16_t sum;
				uint8_t count, minmax;
				ThreeMeasMixedbit* measpkt;

				// We send the message on a ThreeMeasMixedbit struct (One 16-bit number and two 8-bit numbers)
				call MeasPacket.setPayloadLength(&tmp,sizeof(ThreeMeasMixedbit));
				measpkt = (ThreeMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(ThreeMeasMixedbit)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}

				// Calculate SUM and COUNT (We have AVG for sure)
				sum = calculateQuery(SUM, nodeMeas);
				count = calculateQuery(COUNT, nodeMeas);

				// The other query is MAX
				if (select[0] == MAX || select[1] == MAX)
				{
					// Calculate MAX
					minmax = calculateQuery(MAX, nodeMeas);

					// Node 0 - print results
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULTS: AVG: %.2f, MAX: %d\n", (sum / (float) count), minmax);
						dbg("Measurements", "\n");
					}
				}
				// The other query is MIN
				else
				{
					// Claculate MIN
					minmax = calculateQuery(MIN, nodeMeas);

					// Node 0 - print results
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULTS: AVG: %.2f, MIN: %d\n", (sum / (float) count), minmax);
						dbg("Measurements", "\n");
					}
				}

				// Send message
				if (TOS_NODE_ID != 0)
				{
					// Prepare message
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);

						((ThreeMeasMixedbit*) measpkt)->measurement16bit = sum;
						((ThreeMeasMixedbit*) measpkt)->measurement8bit1 = count;
						((ThreeMeasMixedbit*) measpkt)->measurement8bit2 = minmax;
					}
				}
			}
			// SUM-VAR || COUNT-VAR || AVG-VAR
			else if ((select[0] == VAR && (select[1] != MIN && select[1] != MAX)) || (select[1] == VAR && (select[0] != MIN && select[0] != MAX)))
			{
				uint32_t sumsq;
				uint16_t sum;
				uint8_t count;
				VarMeasSimple* measpkt;

				// We send the message on a VarMeasSimple struct (One 32-bit number, one 16-bit number and one 8-bit number)
				call MeasPacket.setPayloadLength(&tmp,sizeof(VarMeasSimple));
				measpkt = (VarMeasSimple*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasSimple)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}

				// Calculate SUMSQ, SUM and COUNT (We have VAR for sure)
				sumsq = calculateQuery(SUMSQ, nodeMeas);
				sum = calculateQuery(SUM, nodeMeas);
				count = calculateQuery(COUNT, nodeMeas);

				// The other query is SUM and we are on node 0 - print results
				if ((select[0] == SUM || select[1] == SUM) && TOS_NODE_ID == 0)
				{
					dbg("Measurements", "\n");
					dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, SUM: %d\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), sum);
					dbg("Measurements", "\n");
				}
				// The other query is COUNT and we are on node 0 - print results
				else if ((select[0] == COUNT || select[1] == COUNT) && TOS_NODE_ID == 0)
				{
					dbg("Measurements", "\n");
					dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, COUNT: %d\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), count);
					dbg("Measurements", "\n");
				}
				// The other query is AVG and we are on node 0 - print results
				else if (TOS_NODE_ID == 0)
				{
					dbg("Measurements", "\n");
					dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, AVG: %.2f\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), (sum / (float) count));
					dbg("Measurements", "\n");
				}

				// Send message
				if (TOS_NODE_ID != 0)
				{
					// Prepare message
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);

						((VarMeasSimple*) measpkt)->measurement32bit = sumsq;
						((VarMeasSimple*) measpkt)->measurement16bit = sum;
						((VarMeasSimple*) measpkt)->measurement8bit = count;
					}
				}
			}
			// Queries: MAX-VAR || MIN-VAR
			else
			{
				uint32_t sumsq;
				uint16_t sum;
				uint8_t count, minmax;
				VarMeasDouble* measpkt;

				// We send the message on a VarMeasDouble struct (One 32-bit number, one 16-bit number and two 8-bit numbers)
				call MeasPacket.setPayloadLength(&tmp,sizeof(VarMeasDouble));
				measpkt = (VarMeasDouble*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasDouble)));

				// error
				if(measpkt==NULL)
				{
					dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
					return;
				}
				
				// Calculate SUMSQ, SUM and COUNT (We have VAR for sure)
				sumsq = calculateQuery(SUMSQ, nodeMeas);
				sum = calculateQuery(SUM, nodeMeas);
				count = calculateQuery(COUNT, nodeMeas);

				// The other query is MAX
				if (select[0] == MAX || select[1] == MAX)
				{
					// Calculate MAX
					minmax = calculateQuery(MAX, nodeMeas);

					// Node 0 - print results
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, MAX: %d\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), minmax);
						dbg("Measurements", "\n");
					}
				}
				// The other query is MIN
				else
				{
					// Calculate MIN
					minmax = calculateQuery(MIN, nodeMeas);

					// Node 0 - print results
					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, MIN: %d\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), minmax);
						dbg("Measurements", "\n");
					}
				}

				// Send message
				if (TOS_NODE_ID != 0)
				{
					// Prepare message
					atomic
					{
						call MeasAMPacket.setDestination(&tmp, parentID);

						((VarMeasDouble*) measpkt)->measurement32bit = sumsq;
						((VarMeasDouble*) measpkt)->measurement16bit = sum;
						((VarMeasDouble*) measpkt)->measurement8bit1 = count;
						((VarMeasDouble*) measpkt)->measurement8bit2 = minmax;
					}
				}
			}
		}

		// We want to send the message - passed TCT and it isn't node 0
		if (TOS_NODE_ID != 0 && ((mode == 1 && TinaPass) || mode == 0))
		{

			// Copy message to radioMeasSendPkt because it's global
			atomic
			{
				memcpy(&radioMeasSendPkt,&tmp,sizeof(message_t));
			}
			
			// Set destination
			mdest= call MeasAMPacket.destination(&radioMeasSendPkt);
			
			mlen = call MeasPacket.payloadLength(&radioMeasSendPkt);

			// Send message
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
		// Didn't pass tct
		else if (mode == 1 && TOS_NODE_ID != 0)
		{
			dbg("Tina", "Doesn't send because of tct\n");
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
		radioMeasRecPkt = call MeasReceiveQueue.dequeue();
		
		// find payload length
		len = call MeasPacket.payloadLength(&radioMeasRecPkt);

		// find source (child)
		msource = call MeasAMPacket.source(&radioMeasRecPkt);
		
		dbg("SRTreeC","receiveMeasTask(): len=%u \n",len);


		// Tina mode || Extended TAG with 1 query
		if (mode == 1 || (mode == 0 && select[1] == 0))	
		{
			// Query: SUM
			if (select[0] == SUM)
			{
				// Get payload
				mr = (OneMeas16bit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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
						
						children[i].sum = ((OneMeas16bit*) mr)->measurement;

						dbg("Measurements" , "Received from childID: %d - sum:%d\n", children[i].childID, children[i].sum);
						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
			// Query: AVG (Extended TAG only)
			else if (select[0] == AVG)
			{
				mr = (TwoMeasMixedbit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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
						
						children[i].sum = ((TwoMeasMixedbit*) mr)->measurement16bit;
						children[i].count = ((TwoMeasMixedbit*) mr)->measurement8bit;

						dbg("Measurements" , "Received from childID: %d - sum:%d, count: %d\n", children[i].childID, children[i].sum, children[i].count);
						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
			// Query: VAR (Extended TAG only)
			else if (select[0] == VAR)
			{
				mr = (VarMeasSimple*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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
						
						children[i].sumsq = ((VarMeasSimple*) mr)->measurement32bit;
						children[i].sum = ((VarMeasSimple*) mr)->measurement16bit;
						children[i].count = ((VarMeasSimple*) mr)->measurement8bit;

						dbg("Measurements" , "Received from childID: %d - sumsq: %d, sum:%d, count: %d\n", children[i].childID, children[i].sumsq, children[i].sum, children[i].count);
						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
			// Queries: MAX || MIN || COUNT
			else
			{
				mr = (OneMeas8bit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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
						
						// MAX query
						if (select[0] == MAX)
						{
							children[i].max = ((OneMeas8bit*) mr)->measurement;

							dbg("Measurements" , "Received from childID: %d - max: %d\n", children[i].childID, children[i].max);
						}
						// MIN query
						else if (select[0] == MIN)
						{
							children[i].min = ((OneMeas8bit*) mr)->measurement;

							dbg("Measurements" , "Received from childID: %d - min: %d\n", children[i].childID, children[i].min);
						}
						// COUNT query
						else
						{
							children[i].count = ((OneMeas8bit*) mr)->measurement;

							dbg("Measurements" , "Received from childID: %d - count: %d\n", children[i].childID, children[i].count);
						}

						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
		}
		else 	// Extended TAG with 2 queries
		{
			// Queries: MAX-MIN || MAX-COUNT || MIN-COUNT
			if ((select[0] == MAX || select[0] == MIN || select[0] == COUNT) && (select[1] == MAX || select[1] == MIN || select[1] == COUNT))
			{
				// Holds type of queries
				uint8_t measurementQueries[MAX_QUERIES];

				mr = (TwoMeas8bit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

				// Save type of queries
				measurementQueries[0] = ((TwoMeas8bit*) mr)->measurementQueries[0];
				measurementQueries[1] = ((TwoMeas8bit*) mr)->measurementQueries[1];

				dbg("Tests", "q0: %d, q1: %d\n", measurementQueries[0], measurementQueries[1]);

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

						// First query is MAX
						if (measurementQueries[0] == MAX)
						{
							children[i].max = ((TwoMeas8bit*) mr)->measurement1;

							dbg("Measurements" , "Received from childID: %d - MAX: %d\n", children[i].childID, children[i].max);
						}
						// First query is MIN
						else if (measurementQueries[0] == MIN)
						{
							children[i].min = ((TwoMeas8bit*) mr)->measurement1;

							dbg("Measurements" , "Received from childID: %d - MIN: %d\n", children[i].childID, children[i].min);
						}
						// First query is COUNT
						else
						{
							children[i].count = ((TwoMeas8bit*) mr)->measurement1;

							dbg("Measurements" , "Received from childID: %d - COUNT: %d\n", children[i].childID, children[i].count);
						}

						// Second query is MAX
						if (measurementQueries[1] == MAX)
						{
							children[i].max = ((TwoMeas8bit*) mr)->measurement2;

							dbg("Measurements" , "Received from childID: %d - MAX: %d\n", children[i].childID, children[i].max);
						}
						// Second query is MIN
						else if (measurementQueries[1] == MIN)
						{
							children[i].min = ((TwoMeas8bit*) mr)->measurement2;

							dbg("Measurements" , "Received from childID: %d - MIN: %d\n", children[i].childID, children[i].min);
						}
						// Second query is COUNT
						else
						{
							children[i].count = ((TwoMeas8bit*) mr)->measurement2;

							dbg("Measurements" , "Received from childID: %d - COUNT: %d\n", children[i].childID, children[i].count);
						}

						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
			// Queries: SUM-MAX || SUM-MIN || SUM-COUNT || SUM-AVG || AVG-COUNT
			else if ((select[0] == SUM && select[1] != VAR)  || (select[1] == SUM && select[0] != VAR) || (select[0] == AVG && select[1] == COUNT)  || (select[1] == AVG && select[0] == COUNT))
			{
				mr = (TwoMeasMixedbit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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

						// SUM will be in the message for sure
						children[i].sum = ((TwoMeasMixedbit*) mr)->measurement16bit;

						// The other query is AVG or COUNT
						if (select[0] == AVG || select[1] == AVG || select[0] == COUNT || select[1] == COUNT)
						{
							children[i].count = ((TwoMeasMixedbit*) mr)->measurement8bit;

							dbg("Measurements" , "Received from childID: %d - SUM: %d, COUNT: %d\n", children[i].childID, children[i].sum, children[i].count);
						}
						// The other query is MAX
						else if (select[0] == MAX || select[1] == MAX)
						{
							children[i].max = ((TwoMeasMixedbit*) mr)->measurement8bit;

							dbg("Measurements" , "Received from childID: %d - SUM: %d, MAX: %d\n", children[i].childID, children[i].sum, children[i].max);
						}
						// The other query is MIN
						else if (select[0] == MIN || select[1] == MIN)
						{
							children[i].min = ((TwoMeasMixedbit*) mr)->measurement8bit;

							dbg("Measurements" , "Received from childID: %d - SUM: %d, MIN: %d\n", children[i].childID, children[i].sum, children[i].min);
						}

						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
			// Queries: AVG-MIN || AVG-MAX
			else if ((select[0] == AVG && (select[1] == MIN || select[1] == MAX)) || (select[1] == AVG && (select[0] == MIN || select[0] == MAX)))
			{
				mr = (ThreeMeasMixedbit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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
						
						// AVG will be in the message for sure
						children[i].sum = ((ThreeMeasMixedbit*) mr)->measurement16bit;
						children[i].count = ((ThreeMeasMixedbit*) mr)->measurement8bit1;

						// The other query is MAX
						if (select[0] == MAX || select[1] == MAX)
						{
							children[i].max = ((ThreeMeasMixedbit*) mr)->measurement8bit2;

							dbg("Measurements" , "Received from childID: %d - SUM: %d, COUNT: %d, MAX: %d\n", children[i].childID, children[i].sum, children[i].count, children[i].max);
						}
						// The other query is MIN
						else
						{
							children[i].min = ((ThreeMeasMixedbit*) mr)->measurement8bit2;

							dbg("Measurements" , "Received from childID: %d - SUM: %d, COUNT: %d, MIN: %d\n", children[i].childID, children[i].sum, children[i].count, children[i].min);
						}

						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}	
			// Queries: SUM-VAR || COUNT-VAR || AVG-VAR
			else if ((select[0] == VAR && (select[1] != MIN && select[1] != MAX)) || (select[1] == VAR && (select[0] != MIN && select[0] != MAX)))
			{			
				mr = (VarMeasSimple*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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

						// VAR will be in the message for sure
						children[i].sumsq = ((VarMeasSimple*) mr)->measurement32bit;
						children[i].sum = ((VarMeasSimple*) mr)->measurement16bit;
						children[i].count = ((VarMeasSimple*) mr)->measurement8bit;

						dbg("Measurements" , "Received from childID: %d - SUMSQ: %d, SUM: %d, COUNT: %d\n", children[i].childID, children[i].sumsq, children[i].sum, children[i].count);
						

						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
			// Queries: MAX-VAR || MIN-VAR
			else
			{
				mr = (VarMeasDouble*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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
						
						// VAR will be in the message for sure
						children[i].sumsq = ((VarMeasDouble*) mr)->measurement32bit;
						children[i].sum = ((VarMeasDouble*) mr)->measurement16bit;
						children[i].count = ((VarMeasDouble*) mr)->measurement8bit1;

						// The other query is MAX
						if (select[0] == MAX || select[1] == MAX)
						{
							children[i].max = ((VarMeasDouble*) mr)->measurement8bit2;

							dbg("Measurements" , "Received from childID: %d - SUMSQ: %d, SUM: %d, COUNT: %d, MAX: %d\n", children[i].childID, children[i].sumsq, children[i].sum, children[i].count, children[i].max);
						}
						// The other query is MIN
						else
						{
							children[i].min = ((VarMeasDouble*) mr)->measurement8bit2;

							dbg("Measurements" , "Received from childID: %d - SUMSQ: %d, SUM: %d, COUNT: %d, MIN: %d\n", children[i].childID, children[i].sumsq, children[i].sum, children[i].count, children[i].min);
						}						

						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
		}
		dbg("SRTreeC" , "MeasMsg received from %d !!! \n", msource);
	}


/////////////////////////////////////////////////////////////////////////
///////////////////			FUNCTIONS			////////////////////////
///////////////////////////////////////////////////////////////////////	
////// Function calculating the result of a query
	uint32_t calculateQuery(uint8_t op, uint8_t nodeMeas)
	{
		uint32_t result;
		uint8_t i;

		if (op == SUM)
		{
			result = nodeMeas;

			for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
			{
				dbg("Calc" , "ChildID: %d has sum: %d\n", children[i].childID, children[i].sum);
		
				result += children[i].sum;
			}
			
			dbg("Calc" , "Node's SUM is: %d\n", result);
		}
		else if (op == MAX)
		{
			result = nodeMeas;

			for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
			{
				dbg("Calc" , "ChildID: %d has max: %d\n", children[i].childID, children[i].max);

				result = (result > children[i].max) ? result : children[i].max;
			}

			dbg("Calc" , "Node's MAX is: %d\n", result);
		}
		else if (op == MIN)
		{
			result = nodeMeas;

			for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
			{
				dbg("Calc" , "ChildID: %d has min: %d\n", children[i].childID, children[i].min);

				result = (result < children[i].min) ? result : children[i].min;
			}

			dbg("Calc" , "Node's MIN is: %d\n", result);
		}
		else if (op == COUNT)
		{
			result = 1;

			for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
			{
				dbg("Calc" , "ChildID: %d has count: %d\n", children[i].childID, children[i].count);

				result += children[i].count;
			}

			dbg("Calc" , "Node's COUNT is: %d\n", result);
		}
		else if (op == SUMSQ)
		{
			result = nodeMeas * nodeMeas;

			for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
			{
				dbg("Calc" , "ChildID: %d has sumsq: %d\n", children[i].childID, children[i].sumsq);
		
				result += children[i].sumsq;
			}
			dbg("Calc" , "Node's SUMSQ is: %d\n", result);
		}
		return result;
	}
}
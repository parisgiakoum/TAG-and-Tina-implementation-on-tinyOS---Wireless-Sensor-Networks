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

	// Array holding children received
	ChildInfo children[MAX_CHILDREN];
	
	// Tasks
	task void sendRoutingTask();
	task void receiveRoutingTask();
	task void sendMeasTask();
	task void receiveMeasTask();

	// Functions
	uint32_t calculateQuery(uint8_t op);


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
			uint8_t num;

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
		
		// get payload for rpkt
		if (mode == 1 || (mode == 0 && select[1] != 0))
		{
			rpkt = (Routing4field*) (call RoutingPacket.getPayload(&tmp, sizeof(Routing4field)));

			dbg("SRTreeC","Creating Routing4field...\n");

			if(rpkt==NULL)
			{
				dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
				return;
			}

			atomic
			{
				((Routing4field*)rpkt)->mode = mode;
				((Routing4field*)rpkt)->select = select[0];
				((Routing4field*)rpkt)->depth = curdepth;

				if (mode == 1)
				{
					((Routing4field*)rpkt)->select2ortct = tct;
				}
				else
				{
					((Routing4field*)rpkt)->select2ortct = select[1];
				}
			}
		}
		else
		{
			rpkt = (Routing3field*) (call RoutingPacket.getPayload(&tmp, sizeof(Routing3field)));
			
			dbg("SRTreeC","Creating Routing3field...\n");

			if(rpkt==NULL)
			{
				dbg("SRTreeC","RoutingMsgTimer.fired(): No valid payload... \n");
				return;
			}

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

			// Tina mode || Extended mod, NUM = 1
			if (mode == 1 || (mode == 0 && select[1] == 0))	
			{
				// SUM
				if (select[0] == SUM)
				{
					uint16_t query;

					measpkt = (OneMeas16bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas16bit)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					query = calculateQuery(SUM);

					if (TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULTS: SUM: %d\n", query);
						dbg("Measurements", "\n");
					}
					else if (mode == 1)
					{
						if (roundCounter == 1 || query > previousQuery + ((float) tct / 100) * previousQuery || query < previousQuery - ((float) tct / 100) * previousQuery)
						{
							TinaPass = TRUE;
							dbg("Tina", "Measurement passes tct! Previous query: %d, Now sent: %d\n", previousQuery, query);
						}
						else
						{
							dbg("Tina", "Measurement doesn't pass tct! Previous query: %d, Now measured: %d\n", previousQuery, query);
						}

						if (TinaPass)
						{
							// Prepare message
							atomic
							{
								previousQuery = query;
								call MeasAMPacket.setDestination(&tmp, parentID);

								((OneMeas16bit*) measpkt)->measurement = query;
								call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas16bit));
							}
						}
					}
					else
					{
						atomic
						{
							call MeasAMPacket.setDestination(&tmp, parentID);
							((OneMeas16bit*) measpkt)->measurement = query;
							call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas16bit));							
						}
					}
				}
				// AVG (Extended mode)
				else if (select[0] == AVG)
				{
					uint16_t sum;
					uint8_t count;

					measpkt = (TwoMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeasMixedbit)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					sum = calculateQuery(SUM);
					count = calculateQuery(COUNT);

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
							call MeasPacket.setPayloadLength(&tmp,sizeof(TwoMeasMixedbit));
						}
					}
				}
				// VAR (Extended mode)
				else if (select[0] == VAR)
				{
					uint32_t sumsq;
					uint16_t sum;
					uint8_t count;

					measpkt = (VarMeasSimple*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasSimple)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					sumsq = calculateQuery(SUMSQ);
					sum = calculateQuery(SUM);
					count = calculateQuery(COUNT);

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
							call MeasPacket.setPayloadLength(&tmp,sizeof(VarMeasSimple));
						}
					}
				}
				// MAX || MIN || COUNT
				else
				{
					uint8_t query;

					measpkt = (OneMeas8bit*) (call MeasPacket.getPayload(&tmp, sizeof(OneMeas8bit)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					if (select[0] == MAX)
					{
						query = calculateQuery(MAX);

						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULT: MAX: %d\n", query);
							dbg("Measurements", "\n");
						}
					}
					else if (select[0] == MIN)
					{
						query = calculateQuery(MIN);

						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULT: MIN: %d\n", query);
							dbg("Measurements", "\n");
						}
					}
					else
					{
						query = calculateQuery(COUNT);

						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULT: COUNT: %d\n", query);
							dbg("Measurements", "\n");
						}
					}

					
					if (mode == 1 && TOS_NODE_ID != 0)
					{
						if (roundCounter == 1 || query > previousQuery + ((float) tct / 100) * previousQuery || query < previousQuery - ((float) tct / 100) * previousQuery)
						{
							TinaPass = TRUE;
							dbg("Tina", "Measurement passes tct! Previous query: %d, Now sent: %d\n", previousQuery, query);
						}
						else
						{
							dbg("Tina", "Measurement doesn't pass tct! Previous query: %d, Now measured: %d\n", previousQuery, query);
						}

						if (TinaPass)
						{
							// Prepare message
							atomic
							{
								previousQuery = query;
								call MeasAMPacket.setDestination(&tmp, parentID);

								((OneMeas8bit*) measpkt)->measurement = query;
								call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas8bit));
							}
						}
					}
					else if (TOS_NODE_ID != 0)
					{
						atomic
						{
							call MeasAMPacket.setDestination(&tmp, parentID);

							((OneMeas8bit*) measpkt)->measurement = query;
							call MeasPacket.setPayloadLength(&tmp,sizeof(OneMeas8bit));
						}
					}
				}
			}
			else 	// Extended mode, NUM = 2
			{
				// MAX-MIN || MAX-COUNT || MIN-COUNT
				if ((select[0] == MAX || select[0] == MIN || select[0] == COUNT) && (select[1] == MAX || select[1] == MIN || select[1] == COUNT))
				{
					uint8_t query[MAX_QUERIES], measurementQueries[MAX_QUERIES], curQuery;

					curQuery = 0;
					measpkt = (TwoMeas8bit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeas8bit)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					if (select[0] == MAX || select[1] == MAX)
					{
						query[curQuery] = calculateQuery(MAX);
						measurementQueries[curQuery] = MAX;
						
						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements" , "FINAL RESULTS: MAX: %d\n", query[curQuery]);
						}

						curQuery++;
					}

					if (select[0] == MIN || select[1] == MIN)
					{
						query[curQuery] = calculateQuery(MIN);
						measurementQueries[curQuery] = MIN;
						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements" , "FINAL RESULTS: MIN: %d\n", query[curQuery]);
						}

						curQuery++;
					}

					if (select[0] == COUNT || select[1] == COUNT)
					{
						query[curQuery] = calculateQuery(COUNT);
						measurementQueries[curQuery] = COUNT;
						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements" , "FINAL RESULTS: COUNT: %d\n", query[curQuery]);
						}

						curQuery++;
					}

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
							call MeasPacket.setPayloadLength(&tmp,sizeof(TwoMeas8bit));
						}
					}
				}
				// SUM-MAX || SUM-MIN || SUM-COUNT || SUM-AVG || AVG-COUNT
				else if ((select[0] == SUM && select[1] != VAR)  || (select[1] == SUM && select[0] != VAR) || (select[0] == AVG && select[1] == COUNT)  || (select[1] == AVG && select[0] == COUNT))
				{
					uint16_t query16;
					uint8_t query8;

					measpkt = (TwoMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(TwoMeasMixedbit)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					query16 = calculateQuery(SUM);

					if (select[0] == AVG || select[1] == AVG)
					{
						query8 = calculateQuery(COUNT);

						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							if (select[0] == SUM || select[1] == SUM)
							{
								dbg("Measurements" , "FINAL RESULTS: AVG: %.2f, SUM: %d\n", (query16 / (float) query8), query16);
							}
							else
							{
								dbg("Measurements" , "FINAL RESULTS: AVG: %.2f, COUNT: %d\n", (query16 / (float) query8), query8);
							}
							dbg("Measurements", "\n");
						}
					}
					else
					{
						if (select[0] == MAX || select[1] == MAX)
						{
							query8 = calculateQuery(MAX);
							
							if (TOS_NODE_ID == 0)
							{
								dbg("Measurements", "\n");
								dbg("Measurements" , "FINAL RESULTS: SUM: %d, MAX: %d\n", query16, query8);
								dbg("Measurements", "\n");
							}
						}
						else if (select[0] == MIN || select[1] == MIN)
						{
							query8 = calculateQuery(MIN);
							
							if (TOS_NODE_ID == 0)
							{
								dbg("Measurements", "\n");
								dbg("Measurements" , "FINAL RESULTS: SUM: %d, MIN: %d\n", query16, query8);
								dbg("Measurements", "\n");
							}
						}
						else
						{
							query8 = calculateQuery(COUNT);
							
							if (TOS_NODE_ID == 0)
							{
								dbg("Measurements", "\n");
								dbg("Measurements" , "FINAL RESULTS: SUM: %d, COUNT: %d\n", query16, query8);
								dbg("Measurements", "\n");
							}
						}
					}

					if (TOS_NODE_ID != 0)
					{
						// Prepare message
						atomic
						{
							call MeasAMPacket.setDestination(&tmp, parentID);

							((TwoMeasMixedbit*) measpkt)->measurement16bit = query16;
							((TwoMeasMixedbit*) measpkt)->measurement8bit = query8;
							call MeasPacket.setPayloadLength(&tmp,sizeof(TwoMeasMixedbit));
						}
					}
				}
				// AVG-MIN || AVG-MAX
				else if ((select[0] == AVG && (select[1] == MIN || select[1] == MAX)) || (select[1] == AVG && (select[0] == MIN || select[0] == MAX)))
				{
					uint16_t sum;
					uint8_t count, minmax;

					measpkt = (ThreeMeasMixedbit*) (call MeasPacket.getPayload(&tmp, sizeof(ThreeMeasMixedbit)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					sum = calculateQuery(SUM);
					count = calculateQuery(COUNT);

					if (select[0] == MAX || select[1] == MAX)
					{
						minmax = calculateQuery(MAX);

						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULTS: AVG: %.2f, MAX: %d\n", (sum / (float) count), minmax);
							dbg("Measurements", "\n");
						}
					}
					else
					{
						minmax = calculateQuery(MIN);

						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULTS: AVG: %.2f, MIN: %d\n", (sum / (float) count), minmax);
							dbg("Measurements", "\n");
						}
					}

					if (TOS_NODE_ID != 0)
					{
						// Prepare message
						atomic
						{
							call MeasAMPacket.setDestination(&tmp, parentID);

							((ThreeMeasMixedbit*) measpkt)->measurement16bit = sum;
							((ThreeMeasMixedbit*) measpkt)->measurement8bit1 = count;
							((ThreeMeasMixedbit*) measpkt)->measurement8bit2 = minmax;
							call MeasPacket.setPayloadLength(&tmp,sizeof(ThreeMeasMixedbit));
						}
					}
				}
				// SUM-VAR || COUNT-VAR || AVG-VAR
				else if ((select[0] == VAR && (select[1] != MIN && select[1] != MAX)) || (select[1] == VAR && (select[0] != MIN && select[0] != MAX)))
				{
					uint32_t sumsq;
					uint16_t sum;
					uint8_t count;

					measpkt = (VarMeasSimple*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasSimple)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					sumsq = calculateQuery(SUMSQ);
					sum = calculateQuery(SUM);
					count = calculateQuery(COUNT);

					if ((select[0] == SUM || select[1] == SUM) && TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, SUM: %d\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), sum);
						dbg("Measurements", "\n");
					}
					else if ((select[0] == COUNT || select[1] == COUNT) && TOS_NODE_ID == 0)
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, COUNT: %d\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), count);
						dbg("Measurements", "\n");
					}
					else if (TOS_NODE_ID == 0) // VAR - AVG
					{
						dbg("Measurements", "\n");
						dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, AVG: %.2f\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), (sum / (float) count));
						dbg("Measurements", "\n");
					}

					if (TOS_NODE_ID != 0)
					{
						// Prepare message
						atomic
						{
							call MeasAMPacket.setDestination(&tmp, parentID);

							((VarMeasSimple*) measpkt)->measurement32bit = sumsq;
							((VarMeasSimple*) measpkt)->measurement16bit = sum;
							((VarMeasSimple*) measpkt)->measurement8bit = count;
							call MeasPacket.setPayloadLength(&tmp,sizeof(VarMeasSimple));
						}
					}
				}
				// MAX-VAR || MIN-VAR
				else
				{
					uint32_t sumsq;
					uint16_t sum;
					uint8_t count, minmax;

					measpkt = (VarMeasDouble*) (call MeasPacket.getPayload(&tmp, sizeof(VarMeasDouble)));

					// error
					if(measpkt==NULL)
					{
						dbg("SRTreeC","SendMeasTimer.fired(): No valid payload... \n");
						return;
					}

					sumsq = calculateQuery(SUMSQ);
					sum = calculateQuery(SUM);
					count = calculateQuery(COUNT);

					if (select[0] == MAX || select[1] == MAX)
					{
						minmax = calculateQuery(MAX);

						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, MAX: %d\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), minmax);
							dbg("Measurements", "\n");
						}
					}
					else
					{
						minmax = calculateQuery(MIN);

						if (TOS_NODE_ID == 0)
						{
							dbg("Measurements", "\n");
							dbg("Measurements" , "FINAL RESULTS: VAR: %.2f, MIN: %d\n", ((sumsq / (float) count) - ((sum / (float) count) * (sum / (float) count))), minmax);
							dbg("Measurements", "\n");
						}
					}

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
							call MeasPacket.setPayloadLength(&tmp,sizeof(VarMeasDouble));
						}
					}
				}
			}

			if (TOS_NODE_ID != 0 && ((mode == 1 && TinaPass) || mode == 0))
			{
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
					dbg("SRTreeC","MeasMsg failed to be enqueued in MeasSendQueue!!!\n");
				}		
			}
			else if (mode == 1 && TOS_NODE_ID != 0)
			{
				dbg("Tina", "Doesn't send because of tct\n");
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
		if (mode == 1 || (mode == 0 && select[1] != 0))
		{
			sendDone=call RoutingAMSend.send(AM_BROADCAST_ADDR,&radioRoutingSendPkt,sizeof(Routing4field));
		}
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
				if (len == sizeof(Routing4field))
				{
					Routing4field * rpkt = (Routing4field*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
					dbg("SRTreeC" , "receiveRoutingTask(): source= %d , depth= %d \n", msource , rpkt->depth);


					// Assign source as parent
					parentID = msource;
					mode = rpkt->mode;
					curdepth = rpkt->depth + 1;
					select[0] = rpkt->select;
					
					dbg("RoutingMsg" , "New parent for NodeID= %d : curdepth= %d , parentID= %d \n", TOS_NODE_ID ,curdepth , parentID);

					if (mode == 1)
					{
						tct = rpkt->select2ortct;
						dbg("Tina", "tinaSelect= %d , tct=%d\n", select[0], tct);
					}
					else
					{
						select[1] = rpkt->select2ortct;
						dbg("Extend", "ExtendSelect1= %d, ExtendSelect2= %d\n", select[0], select[1]);
					}

				}
				else
				{
					Routing3field* rpkt = (Routing3field*) (call RoutingPacket.getPayload(&radioRoutingRecPkt,len));
					dbg("SRTreeC" , "receiveRoutingTask(): source= %d , depth= %d \n", msource , rpkt->depth);

					// Assign source as parent
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


		// Tina mode || Extended mod, NUM = 1
		if (mode == 1 || (mode == 0 && select[1] == 0))	
		{
			// SUM
			if (select[0] == SUM)
			{
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
			// AVG (Extended mode)
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
			// VAR (Extended mode)
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
			// MAX || MIN || COUNT
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
						
						if (select[0] == MAX)
						{
							children[i].max = ((OneMeas8bit*) mr)->measurement;

							dbg("Measurements" , "Received from childID: %d - max: %d\n", children[i].childID, children[i].max);
						}
						else if (select[0] == MIN)
						{
							children[i].min = ((OneMeas8bit*) mr)->measurement;

							dbg("Measurements" , "Received from childID: %d - min: %d\n", children[i].childID, children[i].min);
						}
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
		else 	// Extended mode, NUM = 2
		{
			// MAX-MIN || MAX-COUNT || MIN-COUNT
			if ((select[0] == MAX || select[0] == MIN || select[0] == COUNT) && (select[1] == MAX || select[1] == MIN || select[1] == COUNT))
			{
				uint8_t measurementQueries[MAX_QUERIES];

				mr = (TwoMeas8bit*) (call MeasPacket.getPayload(&radioMeasRecPkt,len));

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

						if (measurementQueries[0] == MAX)
						{
							children[i].max = ((TwoMeas8bit*) mr)->measurement1;

							dbg("Measurements" , "Received from childID: %d - MAX: %d\n", children[i].childID, children[i].max);
						}
						else if (measurementQueries[0] == MIN)
						{
							children[i].min = ((TwoMeas8bit*) mr)->measurement1;

							dbg("Measurements" , "Received from childID: %d - MIN: %d\n", children[i].childID, children[i].min);
						}
						else
						{
							children[i].count = ((TwoMeas8bit*) mr)->measurement1;

							dbg("Measurements" , "Received from childID: %d - COUNT: %d\n", children[i].childID, children[i].count);
						}

						if (measurementQueries[1] == MAX)
						{
							children[i].max = ((TwoMeas8bit*) mr)->measurement2;

							dbg("Measurements" , "Received from childID: %d - MAX: %d\n", children[i].childID, children[i].max);
						}
						else if (measurementQueries[1] == MIN)
						{
							children[i].min = ((TwoMeas8bit*) mr)->measurement2;

							dbg("Measurements" , "Received from childID: %d - MIN: %d\n", children[i].childID, children[i].min);
						}
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
			// SUM-MAX || SUM-MIN || SUM-COUNT || SUM-AVG || AVG-COUNT
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

						children[i].sum = ((TwoMeasMixedbit*) mr)->measurement16bit;

						if (select[0] == AVG || select[1] == AVG || select[0] == COUNT || select[1] == COUNT)
						{
							children[i].count = ((TwoMeasMixedbit*) mr)->measurement8bit;

							dbg("Measurements" , "Received from childID: %d - SUM: %d, COUNT: %d\n", children[i].childID, children[i].sum, children[i].count);
						}
						else if (select[0] == MAX || select[1] == MAX)
						{
							children[i].max = ((TwoMeasMixedbit*) mr)->measurement8bit;

							dbg("Measurements" , "Received from childID: %d - SUM: %d, MAX: %d\n", children[i].childID, children[i].sum, children[i].max);
						}
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
			// AVG-MIN || AVG-MAX
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

						children[i].sum = ((ThreeMeasMixedbit*) mr)->measurement16bit;
						children[i].count = ((ThreeMeasMixedbit*) mr)->measurement8bit1;

						if (select[0] == MAX || select[1] == MAX)
						{
							children[i].max = ((ThreeMeasMixedbit*) mr)->measurement8bit2;

							dbg("Measurements" , "Received from childID: %d - SUM: %d, COUNT: %d, MAX: %d\n", children[i].childID, children[i].sum, children[i].count, children[i].max);
						}
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
			// SUM-VAR || COUNT-VAR || AVG-VAR
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

						children[i].sumsq = ((VarMeasSimple*) mr)->measurement32bit;
						children[i].sum = ((VarMeasSimple*) mr)->measurement16bit;
						children[i].count = ((VarMeasSimple*) mr)->measurement8bit;

						dbg("Measurements" , "Received from childID: %d - SUMSQ: %d, SUM: %d, COUNT: %d\n", children[i].childID, children[i].sumsq, children[i].sum, children[i].count);
						

						// Child is assigned on the table - stop itteration
						break;
					}
				}
			}
			// MAX-VAR || MIN-VAR
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

						children[i].sumsq = ((VarMeasDouble*) mr)->measurement32bit;
						children[i].sum = ((VarMeasDouble*) mr)->measurement16bit;
						children[i].count = ((VarMeasDouble*) mr)->measurement8bit1;

						if (select[0] == MAX || select[1] == MAX)
						{
							children[i].max = ((VarMeasDouble*) mr)->measurement8bit2;

							dbg("Measurements" , "Received from childID: %d - SUMSQ: %d, SUM: %d, COUNT: %d, MAX: %d\n", children[i].childID, children[i].sumsq, children[i].sum, children[i].count, children[i].max);
						}
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
	uint32_t calculateQuery(uint8_t op)
	{
		uint32_t result;
		uint8_t i;

		if (op == SUM)
		{
			result = measurement;

			for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
			{
				dbg("Calc" , "ChildID: %d has sum: %d\n", children[i].childID, children[i].sum);
		
				result += children[i].sum;
			}
			
			dbg("Calc" , "Node's SUM is: %d\n", result);
		}
		else if (op == MAX)
		{
			result = measurement;

			for (i=0; i < MAX_CHILDREN && children[i].childID != 0; i++)
			{
				dbg("Calc" , "ChildID: %d has max: %d\n", children[i].childID, children[i].max);

				result = (result > children[i].max) ? result : children[i].max;
			}

			dbg("Calc" , "Node's MAX is: %d\n", result);
		}
		else if (op == MIN)
		{
			result = measurement;

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
			result = measurement * measurement;

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
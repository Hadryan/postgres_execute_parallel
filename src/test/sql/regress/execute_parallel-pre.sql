/**
 * Based on code from Joe Conway <mail@joeconway.com>
 * https://www.postgresql-archive.org/How-to-run-in-parallel-in-Postgres-td6114510.html
 * 
 */

DROP FUNCTION IF EXISTS execute_parallel(stmts text[]);
DROP FUNCTION IF EXISTS execute_parallel(stmts text[], num_parallel_thread int);

-- TODO add test return value
-- TODO catch error on main loop to be sure connenctinos are closed

CREATE OR REPLACE FUNCTION execute_parallel(stmts text[], num_parallel_thread int DEFAULT 3)
RETURNS boolean AS
$$
declare
  i int = 1;
  current_stmt_index int = 1;
  current_stmt_sent int = 0;
  new_stmt text;
  num_stmts_executed int = 0;
  num_stmts_failed int = 0;
  num_conn_opened int = 0;
  num_conn_notify int = 0;
  retv text;
  retvnull text;
  conn_status int;
  conntions_array text[];
  conn_stmts text[];
  connstr text;
  rv int;
  new_stmts_started boolean; 
  v_state text;
  v_msg text;
  v_detail text;
  v_hint text;
  v_context text;
  

  db text := current_database();
begin
	
	IF (Array_length(stmts, 1) IS NULL OR stmts IS NULL) THEN
       RAISE NOTICE 'No statements to execute';
       RETURN TRUE;
    ELSE
       RAISE NOTICE '% statements to execute in % threads', Array_length(stmts, 1), num_parallel_thread;
    END IF;
 	
	
	-- Check if num parallel theads if bugger than num stmts
	IF (num_parallel_thread > array_length(stmts,1)) THEN
  	  	num_parallel_thread = array_length(stmts,1);
  	END IF;

  	connstr := 'dbname=' || db;

  	
  	-- Open connections for num_parallel_thread
	BEGIN
	  	for i in 1..num_parallel_thread loop
		    conntions_array[i] := 'conn' || i::text;
		    perform dblink_connect(conntions_array[i], connstr);
		    num_conn_opened := num_conn_opened + 1;
		    conn_stmts[i] := null;
		end loop;
	EXCEPTION WHEN OTHERS THEN
	  	
	    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL, v_hint = PG_EXCEPTION_HINT,
                    v_context = PG_EXCEPTION_CONTEXT;
        RAISE NOTICE 'Failed to open all requested connections % , reduce to  % state  : %  message: % detail : % hint   : % context: %', 
        num_parallel_thread, num_conn_opened, v_state, v_msg, v_detail, v_hint, v_context;
		
		-- Check if num parallel theads if bugger than num stmts
		IF (num_conn_opened < num_parallel_thread) THEN
	  	  	num_parallel_thread = num_conn_opened;
	  	END IF;

	END;


	IF (num_conn_opened > 0) THEN
	  	-- Enter main loop
	  	LOOP 
	  	  new_stmts_started = false;
	  
		 -- check if connections are not used
		 FOR i IN 1..num_parallel_thread loop
		    IF (conn_stmts[i] is not null) THEN 
		      --select count(*) from dblink_get_notify(conntions_array[i]) into num_conn_notify;
		      --IF (num_conn_notify is not null and num_conn_notify > 0) THEN
		      SELECT dblink_is_busy(conntions_array[i]) into conn_status;
		      IF (conn_status = 0) THEN
			    conn_stmts[i] := null;
			    num_stmts_executed := num_stmts_executed + 1;
		    	BEGIN

			    	LOOP 
			    	  select val into retv from dblink_get_result(conntions_array[i]) as d(val text);
			    	  EXIT WHEN retv is null;
			    	END LOOP ;

				EXCEPTION WHEN OTHERS THEN
				    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL, v_hint = PG_EXCEPTION_HINT,
                    v_context = PG_EXCEPTION_CONTEXT;
                    RAISE NOTICE 'Failed get value for stmt: %s , using conn %, state  : % message: % detail : % hint : % context: %', conn_stmts[i], conntions_array[i], v_state, v_msg, v_detail, v_hint, v_context;
					num_stmts_failed := num_stmts_failed + 1;
		   	 	    perform dblink_disconnect(conntions_array[i]);
		            perform dblink_connect(conntions_array[i], connstr);
				END;
		      END IF;
		    END IF;
	        IF conn_stmts[i] is null AND current_stmt_index <= array_length(stmts,1) THEN
	            -- start next job
	            -- TODO remove duplicate job
		        new_stmt := stmts[current_stmt_index];
		        conn_stmts[i] :=  new_stmt;
		   		RAISE NOTICE 'New stmt (%) on connection %', new_stmt, conntions_array[i];
	    	    BEGIN
			    --rv := dblink_send_query(conntions_array[i],'BEGIN; '||new_stmt|| '; COMMIT;');
			    rv := dblink_send_query(conntions_array[i],new_stmt);
--		   	 	    perform dblink_disconnect(conntions_array[i]);
--		            perform dblink_connect(conntions_array[i], connstr);
			    new_stmts_started = true;
			    EXCEPTION WHEN OTHERS THEN
			      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL, v_hint = PG_EXCEPTION_HINT,
                  v_context = PG_EXCEPTION_CONTEXT;
                  RAISE NOTICE 'Failed to send stmt: %s , using conn %, state  : % message: % detail : % hint : % context: %', conn_stmts[i], conntions_array[i], v_state, v_msg, v_detail, v_hint, v_context;
				  num_stmts_failed := num_stmts_failed + 1;
		   	 	  perform dblink_disconnect(conntions_array[i]);
		          perform dblink_connect(conntions_array[i], connstr);
			    END;
				current_stmt_index = current_stmt_index + 1;
			END IF;
		    
		    
		  END loop;
		  
		  EXIT WHEN num_stmts_executed = Array_length(stmts, 1); 
		  
		  -- Do a slepp if nothings happens to reduce CPU load 
		  IF (new_stmts_started = false) THEN 
		  	--RAISE NOTICE 'Do sleep at num_stmts_executed %s current_stmt_index =% , array_length= %, new_stmts_started = %', 
		  	--num_stmts_executed,current_stmt_index, array_length(stmts,1), new_stmts_started;
			perform pg_sleep(0.0001);
		  END IF;
		END LOOP ;
	
		-- cose connections for num_parallel_thread
	  	for i in 1..num_parallel_thread loop
		    perform dblink_disconnect(conntions_array[i]);
		end loop;
  END IF;


  IF num_stmts_failed = 0 AND (current_stmt_index -1)= array_length(stmts,1) THEN
  	return true;
  else
  	return false;
  END IF;
  
END;
$$ language plpgsql;

GRANT EXECUTE on FUNCTION execute_parallel(stmts text[], num_parallel_thread int) TO public;


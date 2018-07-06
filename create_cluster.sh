#!/bin/bash
###########################################################################################
# This script is intended to demonstrate the automated install of ScaleIO MDM,SDS servers.#
# Assumption:  ALL NODES ARE SYMMETRICALLY CONFIGURED 					  #
#											  #
# Created  5/2/2018 steven.sigafoos@emc.com						  #
# Modified 5/11/2018 steven.sigafoos@emc.oom 						  #
# Added automation to allow a list IP addresses to be ingested 				  #
###########################################################################################

# Local variables

DRV_CFG=/opt/emc/scaleio/sdc/bin/drv_cfg
DRV_CFG_TXT=/bin/emc/scaleio/drv_cfg.txt
TOPOLOGY=/tmp/topology.dat
MK_SDC=/tmp/mk_sdc.sh
IP_LIST=/root/build/ip.dat
cat /dev/null > $TOPOLOGY
cat /dev/null > $MK_SDC

# Test for presence of cluster ip file for automation
if [ -f $IP_LIST ]; then
	AUTO=Y
else
	AUTO=N
fi

# Functions 

yesNo () {

	if [[ -n $DEBUG ]]; then 
		set -x 
	fi
		
	while :
	do
		echo -n "$1 "
		read LINE
			
		case $LINE in
			[Yy]) return 0 ;;
			[Nn]) return 1 ;;
			*) echo "Enter Y or N" ;;
		esac
	done
	}

parse () {

	if [[ -n $DEBUG ]]; then 
		set -x 
	fi
		case $1 in 

			TB*|MDM*) line=$(cat $TOPOLOGY | grep $1)
				export ROLE=$(echo $line | awk '{print $1}')
				export SDS=$(echo $line | awk '{print $2}' | tr [:lower:] [:upper:] )
				export MDM_IP=$(echo $line | awk '{print $3}')
				export MDM_MGMT_IPS=$(echo $line | sed -e "s/$ROLE//" -e "s/$SDS//" -e "s/$MDM_IP//" -e 's/^...//' | cut -d"|" -f1 | sed -e 's/ /,/g' -e 's/,$//')
				if [ `echo $line | cut -d"|" -f1 | awk '{print NF}'` -eq  3 ]; then
					 export MDM_MGMT_IPS=$MDM_IP	
				else
					export MDM_MGMT_IPS=$(echo $line | sed -e "s/$ROLE//" -e "s/$SDS//" -e "s/$MDM_IP//" -e 's/^...//' | cut -d"|" -f1 | sed -e 's/ /,/g' -e 's/,$//')
				fi
				export DEVICES=$(echo $line | cut -d "|" -f2 | sed 's/^ //')
				if [ $ROLE == MDM1 ]; then
					export MASTER_MGMT_IPS=$MDM_MGMT_IPS
				fi
				;;
			SDS*) line=$(cat $TOPOLOGY | grep $1)
				export ROLE=$(echo $line | awk '{print $1}')
				export SDS=$(echo $line | awk '{print $2}' | tr [:lower:] [:upper:] )
				export SDS_IP=$(echo $line | awk '{print $3}')
				export MDM_MGMT_IPS=$(echo $line | sed -e "s/$ROLE//" -e "s/$SDS//" -e "s/$SDS_IP//" -e 's/^...//' | cut -d"|" -f1 | sed -e 's/ /,/g' -e 's/,$//')
				if [ `echo $line | cut -d"|" -f1 | awk '{print NF}'` -eq  3 ]; then
					 export MDM_MGMT_IPS=$SDS_IP	
				else
					export MDM_MGMT_IPS=$(echo $line | sed -e "s/$ROLE//" -e "s/$SDS//" -e "s/$SDS_IP//" -e 's/^...//' | cut -d"|" -f1 | sed -e 's/ /,/g' -e 's/,$//')
				fi
				export DEVICES=$(echo $line | cut -d "|" -f2 | sed 's/^ //')
				;;
			SDC*) line=$(cat $TOPOLOGY | grep $1)
				export ROLE=$(echo $line | awk '{print $1}')
				export SDC=$(echo $line | awk '{print $2}' | tr [:lower:] [:upper:] )
				export SDC_IP=$(echo $line | awk '{print $3}')
				if (su - -c "scli --query_cluster | grep N/A" > /dev/null); then 
					#export MDM_MGMT_IPS=$(su - -c "scli --query_cluster | grep Management | head -1 | cut -d":" -f2 | sed -e 's/, M.*$//' -e 's/, /,/g'")	
					export MDM_MGMT_IPS=$(su - -c "scli --query_cluster" | grep Management | awk '{print $2}'| tr -d "\n" | sed 's/,$//')
				else
					export MDM_MGMT_IPS=$(su - -c "scli --query_cluster | grep \"Virtual IPs\"" | cut -d":" -f2 | sed -e 's/, /,/g' -e 's/^ //g')
				fi
				export STORAGE_IPS=$(echo $line | sed -e "s/$ROLE//" -e "s/$SDC//" -e "s/$SDC_IP//" -e 's/^...//' | cut -d"|" -f1 | awk '{print $1}')
				;;
		esac
		return 0
	}

scli_cmd () {

	if [[ -n $DEBUG ]]; then 
		set -x 
	fi
		cmd=$@
		echo -e "#!/bin/sh"  >> /tmp/mk_vip.$$
		echo -e "unlink \"\$1\"" >> /tmp/mk_vip.$$ 
		echo -e "$cmd" >> /tmp/mk_vip.$$ 
		echo -e "y" >> /tmp/mk_vip.$$
		echo -e "EOF" >> /tmp/mk_vip.$$
		bash /tmp/mk_vip.$$ "/tmp/mk_vip.$$" 
		return 0
	}

add_topology () {

	if [[ -n $DEBUG ]]; then 
		set -x 
	fi
		NODE_IP=$1

		# Find all active and configured interfaces for each server
		INTERFACES=$(ssh $NODE_IP ip addr show | awk '$0 !~ /lo:/ && $0 !~ /SLAVE/ && $0 ~ /state UP/{print $2}' | sed 's/://' | tr "\n" " ")
		for intf in $INTERFACES
		do
			# Look for configured interfaces 
			if ( ssh $NODE_IP ip addr show $intf | egrep "inet[ ]" > /dev/null ); then
				ens_ip=$(ssh $NODE_IP ip addr show $intf | awk '$0 ~ /inet[ ]/{print $2}' | cut -d"/" -f1)
				ens_sd=$(ssh $NODE_IP fdisk -l | awk '$1 ~ /^Disk/ && $2 ~ /\/dev\/sd/{print $2}' | grep -v sda | sort | tr "\n" " " | sed -e 's/: /,/g' -e 's/.$//')
				export IPS="$IPS $ens_ip"
			fi
		done

		# Update topology file
		if [ $m_nodes -gt 0 ]; then
			echo "MDM${cnt} SDS${cnt} $IPS | $ens_sd" >> $TOPOLOGY
			m_nodes=$(( m_nodes-1 ))
			cnt=$(( cnt+1 ))
		elif [ $t_nodes -gt 0 ]; then
			echo "TB${t_nodes} SDS${cnt} $IPS | $ens_sd" >> $TOPOLOGY
			MDM=TB
			t_nodes=$(( t_nodes-1 ))
			cnt=$(( cnt+1 ))
		else
			echo "SDS SDS${cnt} $IPS | $ens_sd" >> $TOPOLOGY
			cnt=$(( cnt+1 ))
		fi
			# For HC configurations
			if [ "$SDC" = "Y" ]; then
				echo "SDC SDC${s_cnt} $IPS" >> $TOPOLOGY
				s_cnt=$(( s_cnt+1 ))
			fi
		return 0
	}

config_sdc (){

	if [[ -n $DEBUG ]]; then 
		set -x 
	fi
		SDC=$1
		echo -e "Installing and configuring \"$SDC\"\n"
		parse $SDC
		ssh $SDC_IP mkdir -p /root/build 2> /dev/null
		scp -p /root/build/EMC-ScaleIO-sdc-* $SDC_IP:/root/build
		scp -p /root/build/EMC-ScaleIO-lia-* $SDC_IP:/root/build
		echo -e "#!/bin/sh"  > $MK_SDC
		echo -e "unlink \"\$1\"" >> $MK_SDC
		echo -e "rpm -ivh /root/build/EMC-ScaleIO-sdc-*" >> $MK_SDC
		echo -e "TOKEN=$scaleIO_pw rpm -ivh /root/build/EMC-ScaleIO-lia-*" >> $MK_SDC
		echo -e "echo "mdm ${MDM_MGMT_IPS}" >> $DRV_CFG_TXT" >> $MK_SDC
		scp $MK_SDC $SDC_IP:/tmp > /dev/null 2>&1
		#ssh $SDC_IP bash $MK_SDC "$MK_SDC"  
		ssh $SDC_IP bash $MK_SDC "$MK_SDC"  > /dev/null 2>&1
		ssh $SDC_IP service scini restart
		sleep 2
		return 0
	}

SIO_passwd () {

	if [[ -n $DEBUG ]]; then 
		set -x 
	fi
		stty -echo
		while :
		do
			echo -e "\nSet password for ScaleIO cluster -> \c"; read scaleIO_pw
			echo -e "\nRepeat entry for password of ScaleIO cluster -> \c"; read scaleIO_pw1
			if [ $scaleIO_pw = $scaleIO_pw1 ]; then
				break
			else
				echo -e "\n\n#### Password mismatch please re-enter ####"
			fi
		done
		stty echo
		return 0
	}

##### MAIN

	if [[ -n $DEBUG ]]; then 
		set -x 
	fi

	tput clear
	cat <<-EOF 

	################################################
	 FLEX OS Installation and Configuration Tool
	------------------------------------------------
	 Supports Storage only and HC Configurations
	------------------------------------------------
	     Requires all nodes to be remotely 
	     accessible via passwordless ssh.
	################################################
	EOF

 	PS3="Enter option -> "
 	select menu_list in Cluster SDC Quit
 	do
 		case $menu_list in

		Cluster) cat <<-EOF 

			################################################
			          Available Cluster Models
			------------------------------------------------
			                3-node cluster
			    1 Master MDM 1 Slave MDMs 1 Tie Breaker
			------------------------------------------------
			                5-node cluster
			    1 Master MDM 2 Slave MDMs 2 Tie Breakers
			################################################
			EOF
	
 			PS3="Enter option -> "
			select mode_list in 3_node 5_node Quit
			do
				case $mode_list in
					3_node) MODE=$mode_list
						break ;;
					5_node)MODE=$mode_list
						break ;;
					Quit) exit 0;;
				esac
			done
			
			if [ $MODE = 3_node ]; then 
				m_nodes=2
				t_nodes=1
			elif [ $MODE = 5_node ]; then
				m_nodes=3
				t_nodes=2
			fi
				MIN_NODES=$(echo $MODE | sed 's/_node//')
				# Check for presence of ip.dat file to indicate auto ingest of server IPs
				if [ $AUTO = "Y" ]; then
					CFG_NODES=$( cat $IP_LIST | wc -l)
				else
					echo -e "\nTotal number of nodes to configure (MDM/SDSs + SDSs) -> \c"; read CFG_NODES 
				fi
					if [ $CFG_NODES -lt $MIN_NODES ]; then
						echo "ERROR: The minimum number of nodes for cluster model choosen,"
						echo "is less than the number of nodes to configure"
						exit 1
					fi 
						# Based on number of SDSs <= 10, set spare percentage			
						if [ $CFG_NODES -ge 10 ]; then 
							pct=10
						elif [ $CFG_NODES -eq 9 ]; then
							pct=11
						elif [ $CFG_NODES -eq 8 ]; then
							pct=13
						elif [ $CFG_NODES -eq 7 ]; then
							pct=15
						elif [ $CFG_NODES -eq 6 ]; then
							pct=18
						elif [ $CFG_NODES -eq 5 ]; then
							pct=20
						elif [ $CFG_NODES -eq 4 ]; then
							pct=25
						elif [ $CFG_NODES -eq 3 ]; then
							pct=33
						fi

			# Manual and automated method to add SIO IP addresses
			cnt=1
			c_cnt=1
			s_cnt=1

			if [ $AUTO = "Y" ]; then
				#Add MDMs to topology file first
				cat <<-EOF

				################################################
				   Detected existence of IP list, switching
				    to automated input of cluster nodes 
				------------------------------------------------
				   Discovering networks and local sd devices 
				################################################

				EOF
				echo -e "\tMDMs and TBs\n"
				for NODE_IP in $( cat $IP_LIST | grep MDM | sort -n | awk '{print $2}')
				do
					# Update topology file 
					echo -e "  Processing MDM $NODE_IP"
					add_topology $NODE_IP
					unset IPS SDC
				done
					echo -e "\n\tSDSs\n"
					# Add SDSs to topology 
					for NODE_IP in $( cat $IP_LIST | grep SDS | sort -n | awk '{print $2}')
					do
						# Update topology file 
						echo -e "  Processing SDS $NODE_IP"
						add_topology $NODE_IP
						unset IPS SDC
					done
			else
				# Manual method
				while [ $cnt -le $CFG_NODES ]
				do
					while :
					do
						echo -e "\nEnter Node \"$cnt\" primary IP address -> \c"; read NODE_IP
						if (ping -c1 -w1 $NODE_IP > /dev/null ); then
							break
						else
							echo -e "\nERROR: $NODE_IP does not respond to ping"
						fi
					done
	
						echo -e "\nConfigure SDS for HC with SDC client ? {Y/N] -> \c"; yesNo
						if [ $? = 0 ]; then
							export SDC=Y
						fi
				
					# Update topology file 
					add_topology $NODE_IP
					unset IPS SDC
				done
			fi	
				# Securely define cluster password
				SIO_passwd 
		
				echo -e "\n\n################################################"
				echo -e "   Define Protection Domain Name, Storage Pools"
				echo -e "   and Fault Sets"
				echo -e "################################################\n"
				echo -e "\nEnter Protection Domain Name -> \c"; read PD_Name
				if [ $AUTO = "Y" ]; then
 					echo -e "\nEnter Storage Pool Name -> \c"; read SP_Name
					POOLS=$SP_Name
			
					# Fault Sets
					echo -e "\nConfigure Fault Sets (3)? {Y/N] -> \c"; yesNo
					if [ $? = 0 ]; then
						# Faults are used
						FS_Flag=Y
						cnt=1
						while [ $cnt -le 3 ]
						do
							FS_Name=Rack-$cnt
							FSETS="$FSETS $FS_Name"	
							cnt=$(( cnt+1 ))
						done
					else
						# Fault sets are not used
						FS_Flag=N
					fi
				else
					while :
					do
						echo -e "\nEnter number of storage pools [1-2] -> \c"; read SP_Num
						if ! [[ $SP_Num =~ ^[0-9]$ ]] || [ $SP_Num -gt 2 ]; then
							echo -e "\nNot a valid entry"
						else
							break
						fi
					done	
						# Storage Pools
						cnt=1
						while [ $cnt -le $SP_Num ]
						do
 							echo -e "\nEnter Storage Pool Name -> \c"; read SP_Name
							if ( echo $POOLS | grep $SP_Name > /dev/null ); then
								echo "Name already in-use"
							else
								POOLS="$POOLS $SP_Name"
								cnt=$(( cnt+1 ))
							fi
						done
				fi
		
				# Begin actual deployment
				echo -e "\n\tReady to proceed with deployment of VxFLEX Cluster? [Y/N] --> \c"; yesNo
				if [ $? -eq 1 ]; then 
					echo -e "\nExiting"
					exit 0
				fi 

				# Move and install ScaleIO rpms to all servers
				# Install rpms on all defined servers 
				echo -e "\n################################################"
				echo -e "\tCopy and install SIO rpms"
				echo -e "################################################\n"
				for SRV in $(cat $TOPOLOGY | grep -v SDC | awk '{print $3}')
				do
					ssh $SRV mkdir -p /root/build 2> /dev/null
	 				ROLE=$(cat $TOPOLOGY | awk "\$3 ~ /$SRV/{print \$1}")
			
					for rpm in lia mdm sds sdc
					do      
						scp -p /root/build/EMC-ScaleIO-${rpm}-* $SRV:/root/build
					done 
					echo -e "\nSIO rpms copied to \"$SRV\""
					
					ssh $SRV systemctl stop firewalld.service 
					ssh $SRV systemctl disable firewalld.service 
					ssh $SRV rpm -ivh /root/build/EMC-ScaleIO-sds-* > /dev/null 2>&1
					ssh $SRV TOKEN=$scaleIO_pw rpm -ivh /root/build/EMC-ScaleIO-lia-* > /dev/null 2>&1
			
					# Install MDMs and TBs, except for SDCs
					if ( echo $ROLE | grep MDM > /dev/null ); then 
						mdm="MDM_ROLE_IS_MANAGER=1"
						ssh $SRV $mdm rpm -ivh /root/build/EMC-ScaleIO-mdm-* > /dev/null 2>&1
					elif ( echo $ROLE | grep TB > /dev/null ); then 
						mdm="MDM_ROLE_IS_MANAGER=0"
						ssh $SRV $mdm rpm -ivh /root/build/EMC-ScaleIO-mdm-* > /dev/null 2>&1
					fi
					echo -e "SIO rpms installed on \"$SRV\"\n"
				done

				##### Deploy configuration 
				# Start execution timer
				START_TIME=$SECONDS
			
				for SVC in $(cat $TOPOLOGY | awk '{print $1}')
				do 
					case $SVC in
						MDM1) 	echo -e "\n################################################"
							echo -e "Create Master MDM $SVC, Set Cluster Password"
							echo -e "################################################"
							parse $SVC
							CMD="su - -c \"scli --create_mdm_cluster --master_mdm_ip $MDM_MGMT_IPS --master_mdm_management_ip $MDM_IP --master_mdm_name $SVC --accept_license --approve_certificate\" <<-EOF"
							scli_cmd $CMD 2> /dev/null  
							sleep 5
							su - -c "scli --login --username admin --password admin --approve_certificate" > /dev/null 2>&1
							su - -c "scli --set_password --old_password admin --new_password $scaleIO_pw" > /dev/null2>&1
							su - -c "scli --login --username admin --password $scaleIO_pw" > /dev/null 2>&1
							sleep 1 ;;
						MDM[2-3]) echo -e "\n################################################"
							echo -e "\tAdding Secondary MDM $SVC"
							echo -e "################################################"
							parse $SVC
							CMD="su - -c \"scli --add_standby_mdm --new_mdm_ip $MDM_MGMT_IPS --mdm_role manager --new_mdm_management_ip $MDM_IP --new_mdm_name $SVC --approve_certificate\" <<-EOF"
							scli_cmd $CMD  2> /dev/null  
							sleep 5 ;;
						TB[1-2]) echo -e "\n################################################"
							echo -e "\tAdding Tie Breaker $SVC"
							echo -e "################################################"
							parse $SVC
							sleep 5 
							su - -c "scli --add_standby_mdm --new_mdm_ip $MDM_MGMT_IPS --mdm_role tb --new_mdm_name $SVC --approve_certificate" ;;
					esac
				done
		
				echo -e "\n################################################"
				echo -e "\tSwitching Cluster to $MODE"
				echo -e "################################################"
				SLAVE_NAMES=$(cat $TOPOLOGY | grep -v MDM1 | awk '$1 ~ /MDM/{print $1}' | tr "\n" "," | sed 's/,$//')
				TB_NAMES=$(cat $TOPOLOGY | awk '$1 ~ /TB/{print $1}' | tr "\n" "," | sed 's/,$//')
				su - -c "scli --switch_cluster_mode --cluster_mode $MODE --add_slave_mdm_name $SLAVE_NAMES --add_tb_name $TB_NAMES"
				sleep 5
			
				echo -e "\n################################################"
				echo -e "\tAdding MDM Virtual interfaces and VIPs"
				echo -e "################################################"
				SET_VIP=N  
				for intf in $INTERFACES
				do
					echo -e "\nUse $intf to host a cluster virtual IP address? [Y/N] -> \c"; yesNo
					if [ $? -eq 0 ]; then
						SET_VIP=Y
						# Define interfaces for virtual IPs on Master and Slave MDMs
						V_INTERFACES="$V_INTERFACES $intf"
					echo -e "\nEnter virtual IP address for interface $intf -> \c"; read VIP
						V_IPS="$V_IPS $VIP"
					fi
				done	
				if [ $SET_VIP = Y ]; then 
					#Format variables
					V_INTERFACES=$(echo $V_INTERFACES | sed -e 's/^ //' -e 's/ /,/g')
					V_IPS=$(echo $V_IPS | sed -e 's/^ //' -e 's/ /,/g')
			
					# Create interfaces and virtual IPs on Master and Slave MDMs
					for mdm_ip in $(cat $TOPOLOGY | egrep "^MDM" | awk '{print $3}')
					do
						echo -e "\nCreating Virtual interface(s) on $mdm_ip"
						su - -c "scli --modify_virtual_ip_interfaces --target_mdm_ip $mdm_ip --new_mdm_virtual_ip_interface $V_INTERFACES"
					done
					sleep 5
		
					# Create VIPs
					echo -e "\nCreating Virtual IP(s)\n"
					CMD="su - -c \"scli --modify_cluster_virtual_ips --cluster_virtual_ip $V_IPS\" <<-EOF" 
					scli_cmd $CMD  > /dev/null 2>&1 
					# Show Active VIPs
					for intf in $(echo $V_INTERFACES | sed 's/,/ /g')
					do
						ip addr show $intf | grep ${intf}:mdm
						echo -e ""
					done
					sleep 5
				fi

				echo -e "\n################################################"
				echo -e "   Adding Protection Domain,Storage Pool(s)"
				echo -e "   and Fault Sets"
				echo -e "################################################"
				su - -c "scli --add_protection_domain --protection_domain_name $PD_Name"
				for pool in $POOLS	
				do
					su - -c "scli --add_storage_pool --protection_domain_name $PD_Name --storage_pool_name $pool"
				done
					for FS in $FSETS
					do
						su - -c "scli --add_fault_set --protection_domain_name $PD_Name --fault_set_name $FS" 
					done
				sleep 5

				echo -e "\n################################################"
				echo -e "\tAdd SDS hosts"
				echo -e "################################################"
				# For AUTO install add SDSs indentified in IP_LIST to each Fault Domain 

				INT_POOL=$(echo $POOLS | cut -d" " -f1)

				if [ $AUTO = "Y" ]; then
					# Add SDS with Rack Sets
					if [ $FS_Flag = "Y" ]; then
						for FS in $FSETS
						do
							for rack_ips in $(cat $IP_LIST |  egrep -i "^${FS}-" | awk '{print $2}')
							do
								# Find IP indentity in $IP_LIST from $TOPOLOGY to find SDS 
								SDS_Name=$( cat $TOPOLOGY | awk "\$3 ~ /$rack_ips/{print \$2}") 	
								parse $SDS_Name	
								su - -c "scli --add_sds --sds_ip $MDM_MGMT_IPS --protection_domain_name $PD_Name --storage_pool_name $INT_POOL --sds_name $SDS --fault_set_name $FS"
							done
						done
					else
						# Add SDS Without Rack Sets
						for role in $( cat $TOPOLOGY | awk '$2 ~ /SDS/{print $2}')
						do 
							parse $role	
							su - -c "scli --add_sds --sds_ip $MDM_MGMT_IPS --protection_domain_name $PD_Name --storage_pool_name $INT_POOL --sds_name $SDS"
						done
					fi
							# Add SDs to each SDS
							for role in $( cat $TOPOLOGY | awk '$2 ~ /SDS/{print $2}')
							do 
								parse $role
								echo -e "\n\tAdding local SD devices to $role\n"
								for dev in $(echo $DEVICES | sed 's/,/ /g')
								do 
									su - -c "scli --add_sds_device --sds_name $role  --device_path $dev --storage_pool_name $INT_POOL"
									sleep 1
								done
							done
				else
					# For single SP or dual, istantiate first SP with all devices
					for role in $( cat $TOPOLOGY | awk '$2 ~ /SDS/{print $2}')
					do 
						parse $role
						INT_POOL=$(echo $POOLS | cut -d" " -f1)
						NUM_POOLS=$( echo $POOLS | wc -w) 
						NUM_DEVS=$( echo $DEVICES | awk -F"," '{print NF}')
						DEV_CNT=$(echo $NUM_DEVS $NUM_POOLS | awk '{print tot=$1/$2}')
						P0_CNT=$(echo $DEV_CNT |  awk '{print int($1+0.5)}')
						P0_LST=$(echo $DEVICES | cut -d"," -f1-${P0_CNT})
						if [ $NUM_POOLS -gt 1 ]; then 
							P1_CNT=$(echo $NUM_DEVS $P0_CNT | awk '{print tot=$1-$2}')
							P1_CNT=$(( $P0_CNT+1 ))
							P1_LST=$(echo $DEVICES | cut -d"," -f${P1_CNT}-${NUM_DEVS})
						fi
							SP_DEVS=$P0_LST
							su - -c "scli --add_sds --sds_ip $MDM_MGMT_IPS --device_path $SP_DEVS --protection_domain_name $PD_Name --storage_pool_name $INT_POOL --sds_name $SDS"
					done
					# If using dual SPs, devices are added in a singular fashion by SDS
					if [ $NUM_POOLS -eq 2 ]; then 
						SEC_POOL=$(echo $POOLS | awk '{print $2}')
						SP_DEVS=$( echo $P1_LST | sed 's/,/ /g')
						for role in $( cat $TOPOLOGY | awk '$2 ~ /SDS/{print $2}')
						do 
							echo -e "\n\tAdding local SD devices to $role\n"
							for dev in $SP_DEVS 
							do 
								su - -c "scli --add_sds_device --sds_name $role  --device_path $dev --storage_pool_name $SEC_POOL"
								sleep 1
							done
						done
					fi
				fi

				echo -e "\n################################################"
				echo -e "\tSet profile to high performance"
				echo -e "################################################"
				su - -c "scli --set_performance_parameters --all_sds --all_sdc --apply_to_mdm --profile high_performance"
				sleep 1
			
				echo -e "\n################################################"
				echo -e "\tSet cluster name" 
				echo -e "################################################"
				su - -c "scli --rename_system --new_name VxFLEX_OS_Cluster"
			
				ELAPSED_TIME=$(($SECONDS - $START_TIME))
				echo -e "\n################################################"
				echo -e "  Finished SIO install in $ELAPSED_TIME seconds."
				echo -e "################################################"

				# Cluster specific tunings 	
				echo -e "\n################################################"
				echo -e "\tSet Cluster Sparing Policy at $pct"
				echo -e "################################################"
				for pool in $POOLS
				do
					su - -c "scli --modify_spare_policy --protection_domain_name $PD_Name --storage_pool_name $pool --spare_percentage $pct --i_am_sure"
				done
				echo -e "################################################\n"
				echo -e "\nWaiting sparing policy to complete"
				sleep 8
				for pool in $POOLS
				do
					echo -e "\nStorage utilization for storage pool $pool\n"
					su - -c "scli --query_storage_pool --protection_domain_name $PD_Name --storage_pool_name $pool | egrep \"Spare|total| unused |spare\" | grep -v moving" 
					echo ""
				done
				su - -c "scli --query_all | grep $PD_Name | cut -d"," -f4"
				
				# For HC configurations 
				if ( cat $TOPOLOGY | egrep "^SDC" > /dev/null); then
					echo -e "\n################################################"
					echo -e "\tInstall and configure SDCs" 
					echo -e "################################################"
					for SDC in $(cat $TOPOLOGY | awk '$1 ~ /^SDC/{print $2}')
					do
						config_sdc $SDC
						# Rename from GUID to SDC name 
						GUID=$(ssh $SDC_IP $DRV_CFG --query_guid)
						su - -c "scli --rename_sdc --sdc_guid $GUID --new_name $SDC"
					done
				fi 
				exit 0
				 ;;

			SDC) 	cat <<-EOF 

				##################################################
				 Configure standalone or cluster nodes as an SDC.
				--------------------------------------------------
					Requires the SDCs to be remotely 
					accessible via passwordless ssh.
				--------------------------------------------------
						Enter all SDC IPs
					Enter "I" to initiate deployment
				##################################################
				EOF

				# Securely define cluster password
				SIO_passwd

				# Login to cluster
				su - -c "scli --login --username admin --password $scaleIO_pw" > /dev/null 2>&1
	
				# Look for previously created SDCs and set starting enumeration 
				NUM_SDCS=$(scli --query_all_sdc | awk '$5 ~ /^SDC/' | wc -l)
				if [ $NUM_SDCS -eq 0 ]; then
					s_cnt=1
				else 	
					s_cnt=$(( NUM_SDCS+1 ))
				fi

				while :
				do
					# Enter and check SDC IP is alive and passwordless ssh is operational 
					while :
					do
							echo -e "\nEnter SDC${s_cnt} primary IP address, \"I\" to start install -> \c"; read SDC_IP
							if [ "$SDC_IP" = "I" ] || [ "$SDC_IP" = "i" ]; then
								break 2
							fi
								if (ping -c1 -w1 $SDC_IP > /dev/null ); then
									ssh $SDC_IP uname -a > /dev/null 
									break 
								else
									echo -e "\nERROR: $SDC_IP does not respond to ping or"
									echo -e "\npasswordless ssh has failed"
								fi
					done
			
					# Find all active and configured interfaces for each server
					INTERFACES=$(ssh $NODE_IP ip addr show | awk '$0 !~ /lo:/ && $0 !~ /SLAVE/ && $0 ~ /state UP/{print $2}' | sed 's/://' | tr "\n" " ")
					for intf in $INTERFACES
					do
						# Look for configured interfaces 
						if ( ssh $SDC_IP ip addr show $intf | egrep "inet[ ]" > /dev/null ); then
							ens_ip=$(ssh $SDC_IP ip addr show $intf | awk '$0 ~ /inet[ ]/{print $2}' | cut -d"/" -f1)
							IPS="$IPS $ens_ip"
						fi
					done

					echo "SDC SDC${s_cnt} $IPS" >> $TOPOLOGY
					s_cnt=$(( s_cnt+1 ))

					unset IPS 
				done 

				echo -e "\n################################################"
				echo -e "\tInstall and configure SDCs" 
				echo -e "################################################"
				for SDC in $(cat $TOPOLOGY | awk '$1 ~ /^SDC/{print $2}')
				do
					config_sdc $SDC
					# Rename from GUID to SDC name 
					GUID=$(ssh $SDC_IP $DRV_CFG --query_guid)
					su - -c "scli --rename_sdc --sdc_guid $GUID --new_name $SDC"
				done
				exit 0
				 ;;
			Quit) 	exit 0
				;;
		esac
	done

	# CleanUp
	rm -f $TOPOLOGY $MK_SDC
	exit 0


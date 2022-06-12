#!/bin/bash

# Script to backup/restore mysql using mydumper/myloader and storing the backups in Azure blob storage
# Before running make sure zstd dependecies are installd and mydumper v12.3 or newer is installed
# ->  apt-get install libglib2.0-dev zlib1g-dev libpcre3-dev libssl-dev libzstd-dev
# ->  wget https://github.com/mydumper/mydumper/releases/download/v0.12.3-3/mydumper_0.12.3-3-zstd.$(lsb_release -cs)_amd64.deb
# ->  sudo dpkg -i mydumper...
# Run script in the background with: nohup bash script &
# Set enviroment variables: MYSQL_PWD & BLOB_SAS_TOKEN

bkp_pth="/mnt/c/workspace/forter/db_migration"
log_pth="/mnt/c/workspace/forter/db_migration"
blob="https://stpocdevwus201.blob.core.windows.net/blob-db-export-adam"
allowed_commands=["help","backup","restore"]

#Tables to remove before backing up
system_tables=["","",""]

required_software=("azcopy" "wget" "mysql" "mydumper" "myloader")

check_dependencies(){
	echo "Checking ${#required_software[@]} required dependencies..."	
	for var in "${required_software[@]}"
	do
		echo "checking $var"
		hash $var 2>/dev/null || { echo >&2 "Required software $var not installed. Aborting."; exit 1; }
	done
}

emit(){
	echo $1
}

help(){
	echo "Script to copy Forter mySQL to Azure"
	echo "Use the following options to configure:"
	echo "-c (command): MANDATORY, can be backup or restore"
	echo "-h (host): MANDATORY, the hostname of the mysql server"
	echo "-u (username): MANDATORY, the username used to connect to the mySQL"
	echo "-d (database): MANDATORY, the database name to backup or restore to"
	echo "-t (threads): number of threads to use, defaults to 16"
}

backup(){
	#Fetch all existing tables from db
	existing_tables=$(mysql -h $host -u $user -se "use $db; SHOW TABLES;")
	
	#Convert delimeter to ,
	mod_delim_tables=$(echo $existing_tables | sed -e 's/\s\+/,/g')

	#convert to array
	readarray -td, table_array <<<"$mod_delim_tables,"
	#Unset last element to remove trailing new line
	unset 'table_array[-1]'

	#remove system tables that start with "_" and in system_tables array
	for i in "${!table_array[@]}"; do
		#table_array[$i]=${table_array[i]%,*} 
		if [[ ${table_array[i]} == _* || $system_tables =~ ${table_array[i]} ]]; then
			emit "Unsetting: ${table_array[i]}"
			unset 'table_array[i]'
		fi
	done

	#Backup and upload all tables 
	for i in "${!table_array[@]}"; do
		current_table=${table_array[i]}
		emit "Backing up table ${current_table}"
		mydumper --host=$host --user=$user --password=$MYSQL_PWD --outputdir=${bkp_pth}/${current_table}_backup --rows=100000000 --compress --build-empty-files --threads=16 --compress-protocol --trx-consistency-only --ssl  --regex "^($db\.$current_table)" -L ${log_pth}/${current_table}-mydumper-logs.log

		emit "Copying backup of ${current_table} to blob storage..."
		azcopy copy ${bkp_pth}/${current_table}_backup ${blob}${BLOB_SAS_TOKEN} --recursive

		emit "Transfer complete, deleting local copy of ${current_table}"
		rm -r ${bkp_pth}/${current_table}_backup
	done
}

restore(){
	myloader --host=$host --user=$user --password=$MYSQL_PWD --directory=${bkp_pth}/${current_table}_backup --queries-per-transaction=500 --threads=16 --compress-protocol --ssl --verbose=3 -e 2>${log_pth}/${current_table}-myloader-logs-restore.log
}


if [ $# == 0 ] 
then
	help
else
	while getopts c:h:u:d: option
	do 
		case "${option}"
			in
			c)command=${OPTARG};;
			h)host=${OPTARG};;
			u)user=${OPTARG};;
			d)db=${OPTARG};;
		esac
	done
	if [[ -z $host || -z $user || -z $db ]]; then
		emit 'one or more variables are undefined'
		exit 1
	fi
	if [[ -z "${MYSQL_PWD}" || -z "${BLOB_SAS_TOKEN}" ]]; then
		emit "Missing password to db OR blob SAS token in env variables: MYSQL_PWD/BLOB_SAS_TOKEN. Exiting..."
		exit 1
	fi
	check_dependencies
	echo $host $user $db $command
	if [[ $allowed_commands =~ $command ]]; 
	then 
		start=$(date '+%d/%m/%Y %H:%M:%S')
		emit "Start time: ${start}"
		$command
		end=$(date '+%d/%m/%Y %H:%M:%S')
		emit "End time ${end}"
	else
		emit "Invalid argument: $command"
		emit "run with \"help\" for possible arguments"
	fi
	#for var in "$@"
	#do
	#	if [[ $allowed_commands =~ $var ]]; 
	#	then 
	#		$var 
	#	else
	#		echo "Invalid argument: $var"
	#		echo "run with \"help\" for possible arguments"
	#	fi
	#done
fi


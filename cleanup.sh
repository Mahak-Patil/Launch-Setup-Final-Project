#!/bin/bash
./cleanup.sh
# This script launches: database subnet, AWS RDS instances, EC2 instances,read replica of created database, load balancer, cloud metrics and autoscaling group.
# This script needs 7 arguments: ami image-id, number of EC2 instances, instance type, security group ids, subnet id, key name and iam profile

# creating database subnet with my own provided subnet ids
DbSubnetID=$(aws rds create-db-subnet-group --db-subnet-group-name ITMO-544-Database-Subnet --subnet-ids subnet-07dd812c subnet-0fdfdd78 --db-subnet-group-description Database-subnet --output=text )
# echo "\n Database subnet created: "$DbSubnetID
# creating the database. Initial check done in previous, cleanup section.
aws rds create-db-instance --db-instance-identifier ITMO-544-Database --allocated-storage 5 --db-instance-class db.t1.micro --engine MySQL --master-username controller --master-user-password ilovebunnies --db-subnet-group-name ITMO-544-Database-Subnet --db-name ITMO544Database 
aws rds wait db-instance-available --db-instance-identifier ITMO-544-Database

# creating elb 
ElbUrl=$(aws elb create-load-balancer --load-balancer-name ITMO-544-Load-Balancer --security-groups $4 --subnets $5 --listeners Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=80 --output=text)
echo "\n Launched ELB " $ElbUrl " and sleeping for one minute"
for i in {0..60}
 do
  echo -ne '.'
  sleep 1;
  done

# configuring health check
aws elb configure-health-check --load-balancer-name ITMO-544-Load-Balancer --health-check Target=HTTP:80/index.php,Interval=30,UnhealthyThreshold=2,HealthyThreshold=2,Timeout=3
echo -e "\n Configured ELB health check. Proceeding to launch EC2 instances"
  

# registering instances with created elb
declare -a instance_list
mapfile -t instance_list < <(aws ec2 run-instances --image-id $1 --count $2 --instance-type $3 --key-name $4 --security-group-ids $5 --subnet-id $6 --associate-public-ip-address --iam-instance-profile Name=$7 --user-data install-webserver.sh --output table | grep InstanceId | sed "s/|//g" | tr -d ' ' | sed "s/InstanceId//g")
aws ec2 wait instance-running --instance-ids ${instance_list[@]} 
aws ec2 wait instance-running --instance-ids ${instance_list[@]} 
echo "Following instances running: ${instance_list[@]}" 
aws elb register-instances-with-load-balancer --load-balancer-name ITMO-544-Load-Balancer --instances ${instance_list[@]}
echo -e "\n Sleeping for one minute to complete the process."
    for y in {0..60} 
    do
      echo -ne '.'
      sleep 1
    done
 echo "\n"
done


#SNS starts here:
SnsImageARN=(`aws sns create-topic --name SnsImageTopicName`)
aws sns set-topic-attributes --topic-arn $SnsImageARN --attribute-name DisplayName --attribute-value $SnsImageTopicName 


# SNS For Cloud MetricAlarm
SnsCloudMetricARN=(`aws sns create-topic --name CloudMetricTopic`)
aws sns set-topic-attributes --topic-arn $SnsCloudMetricARN --attribute-name DisplayName --attribute-value CloudMetricTopic

#Subcribe

EmailID=mpatil@hawk.iit.edu
aws sns subscribe --topic-arn $SnsCloudMetricARN --protocol email --notification-endpoint $EmailID

# creating launch configuration
aws autoscaling create-launch-configuration --launch-configuration-name ITMO-544-Launch-Configuration --image-id $1 --key-name $6 --security-groups $4 --instance-type $3 --user-data install-webserver.sh --iam-instance-profile $7

# creating autoscaling group and autoscaling policy
aws autoscaling create-auto-scaling-group --auto-scaling-group-name ITMO-544-Auto-Scaling-Group --launch-configuration-name ITMO-544-Launch-Configuration --load-balancer-names ITMO-544-Load-Balancer --health-check-type ELB --min-size 3 --max-size 6 --desired-capacity 3 --default-cooldown 600 --health-check-grace-period 120 --vpc-zone-identifier $5

# creating cloudwatch metric. got most of these directly from the documentation!
IncreaseScaling = $(aws autoscaling put-scaling-policy --auto-scaling-group-name ITMO-544-Auto-Scaling-Group --policy-name ITMO544IncreaseInScalingPolicy --scaling-adjustment 3 --adjustment-type ChangeInCapacity)
DecreaseScaling = $(aws autoscaling put-scaling-policy --auto-scaling-group-name ITMO-544-Auto-Scaling-Group --policy-name ITMO544DecreaseInScalingPolicy --scaling-adjustment -3 --adjustment-type ChangeInCapacity)

aws cloudwatch put-metric-alarm --alarm-name ITMO-544-Add-Alarm --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 60 --threshold 30 --comparison-operator GreaterThanOrEqualToThreshold --dimensions "Name=AutoScalingGroupName,Value=ITMO-544-Auto-Scaling-Group" --evaluation-periods 1 --alarm-actions $IncreaseScaling --unit Percent --alarm-description "Alarm will go off when CPU exceeds 30%"

aws cloudwatch put-metric-alarm --alarm-name ITMO-544-Reduce-Alarm --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 60 --threshold 10 --comparison-operator LessThanOrEqualToThreshold --dimensions "Name=AutoScalingGroupName,Value=ITMO-544-Auto-Scaling-Group" --evaluation-periods 1 --alarm-actions $DecreaseScaling --unit Percent --alarm-description "Alarm will go off when CPU falls below 10%"

# Create read replica
aws rds-create-db-instance-read-replica ITM0-544-Database-Replica --source-db-instance-identifier-value ITMO-544-Database --output=text 

# Creating sns topic
TopicARN = $(aws sns create-topic --name ITMO-544-Notification)
echo "The topic ARN is: "$TopicARN

# Setting an attribute of the above topic to a new value
aws sns set-topic-attributes --topic-arn $TopicARN --attribute-name DisplayName --attribute-value ITMO-544

# subscribing an endpoint to a topic
#aws sns subscribe --topic-arn $TopicARN --protocol sms --notification-endpoint 13123949795

# sending message to a topic's subscribed endpoint
#aws sns publish --topic-arn $TopicARN --message file://sns-message.txt

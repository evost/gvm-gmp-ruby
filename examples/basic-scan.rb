#!/usr/bin/env ruby
# Basic example of gvm-gmp usage

# in case you're using Ruby 1.8 and using gem, you should uncomment line below
# require 'rubygems'
require 'gvm-gmp'

gvm=GVMGMP::GVMGMP.new("user"=>'gvm',"password"=>'gvm')
config=gvm.config_get().index("Full and fast")
target=gvm.target_create({"name"=>"t", "hosts"=>"127.0.0.1", "comment"=>"t"})
taskid=gvm.task_create({"name"=>"t","comment"=>"t", "target"=>target, "config"=>config})
gvm.task_start(taskid)
while not gvm.task_finished(taskid) do
        stat=gvm.task_get_byid(taskid)
        puts "Status: #{stat['status']}, Progress: #{stat['progress']} %"
        sleep 10
end
stat=gvm.task_get_byid(taskid)
content=gvm.report_get_byid(stat["lastreport"],'HTML')
File.open('report.html', 'w') {|f| f.write(content) }


#
# = gvm-gmp.rb: communicate with GVM over GMP
#
# Author:: Vlatko Kosturjak, Konstantin Kraynov
#
# (C) Vlatko Kosturjak, Kost.
# (C) Konstantin Kraynov, Evost.
# Distributed under MIT license:
# http://www.opensource.org/licenses/mit-license.php
# 
# == What is this library? 
# 
# This library is used for communication with GVM over GMP
# You can start, stop, pause and resume scan. Watch progress and status of 
# scan, download report, etc.
#
# == Requirements
# 
# Required libraries are standard Ruby libraries: socket,timeout,openssl,
# rexml/document, rexml/text, base64
#
# == Usage:
# 
#  require 'gvm-gmp'
#
#  gvm=GVMGMP::GVMGMP.new("user"=>'admin',"password"=>'admin', 'path' => path)
#  config=gvm.config_get().index("Full and fast")
#  target=gvm.target_create({"name"=>"t", "hosts"=>"127.0.0.1", "comment"=>"t"})
#  taskid=gvm.task_create({"name"=>"t","comment"=>"t", "target"=>target, "config"=>config})
#  gvm.task_start(taskid)
#  while not gvm.task_finished(taskid) do
#         stat=gvm.task_get_byid(taskid)
#         puts "Status: #{stat['status']}, Progress: #{stat['progress']} %"
#         sleep 10
#  end
#  stat=gvm.task_get_byid(taskid)
#  content=gvm.report_get_byid(stat["lastreport"],'HTML')
#  File.open('report.html', 'w') {|f| f.write(content) }

require 'socket' 
require 'timeout'
require 'openssl'
require 'rexml/document'
require 'rexml/text'
require 'base64'

# GVMGMP module
# 
# Usage:
# 
#  require 'gvm-gmp'
# 
#  gvm=GVMGMP::GVMGMP.new("user"=>'admin',"password"=>'admin')

module GVMGMP

	class GMPError < :: RuntimeError
		attr_accessor :req, :reason
		def initialize(req, reason = '')
			self.req = req
			self.reason = reason
		end
		def to_s
			"GVM GMP: #{self.reason}"
		end
	end

	class GMPResponseError < GMPError
		def initialize
			self.reason = "Error in GMP request/response"
		end
	end

	class GMPAuthError < GMPError
		def initialize
			self.reason = "Authentication failed"
		end
	end

	class XMLParsingError < GMPError
		def initialize
			self.reason = "XML parsing failed"
		end
	end

	# Core class for GMP communication protocol 
	class GVMGMP
		# initialize object: try to connect to GVM using Unix socket, user and password
		#
		# Usage:
		#
		#  gvm=GVMGMP.new(user=>'user',password=>'pass') 
		#  # default: path=>'/run/gvmd/gvmd.sock'
		# 
		def initialize(p={})
			if p.has_key?("path")
				@path=p["path"]
			else
				@path="/run/gvmd/gvmd.sock"
			end
			if p.has_key?("user")
				@user=p["user"]
			else
				@user="admin"
			end
			if p.has_key?("password")
				@password=p["password"]
			else
				@password="admin"
			end
			if p.has_key?("bufsize")
				@bufsize=p["bufsize"]
			else
				@bufsize=16384
			end
			if p.has_key?("debug")
				@debug=p["debug"]
			else
				@debug=0
			end
				
			if @debug>3 
				puts "Socket: "+@path
				puts "User: "+@user
			end
			if @debug>99
				puts "Password: "+@password
			end
			@areq=''
			@read_timeout=3
			if defined? p["noautoconnect"] and not p["noautoconnect"]
				connect()
				if defined? p["noautologin"] and not p["noautologin"]
					login()
				end
			end
		end

		# Sets debug level
		# 
		# Usage:
		#
		# gvm.debug(3)
		#
		def debug (level)
			@debug=level
		end

		# Low level method - Connect to Unix socket
		#
		# Usage:
		#
		# gvm.connect()
		# 
		def connect
            @socket = UNIXSocket.new(@path)
		end


		# Low level method: Send request and receive response - socket
		#
		# Usage:
		#
		# gvm.connect();
		# puts gvm.sendrecv("<get_version/>")
		# 
		def sendrecv (tosend)
			if not @socket
				connect
			end
		
			if @debug>3 then
				puts "SENDING: "+tosend
			end
			@socket.puts(tosend)

			@rbuf=''
			size=0
			begin	
				begin
				Timeout.timeout(@read_timeout) {
				    a = @socket.sysread(@bufsize)
				    size=a.length
				    # puts "sysread #{size} bytes"
				    @rbuf << a
				}
				rescue Timeout::Error
					size=0
				rescue EOFError
					raise GMPResponseError
				end
			end while size>=@bufsize
			response=@rbuf
			
			if @debug>3 then
				puts "RECEIVED: "+response
			end
			return response
		end

		# get GMP version (you don't need to be authenticated)
		#
		# Usage:
		#
		# gvm.version_get()
		# 
		def version_get 
			vreq="<get_version/>"	
			resp=sendrecv(vreq)	
			resp = "<X>"+resp+"</X>"
			begin
				docxml = REXML::Document.new(resp)
				version=''
				version=docxml.root.elements['get_version_response'].elements['version'].text
				return version
			rescue
				raise XMLParsingError 
			end
		end

		# produce single XML element with attributes specified as hash
		# low-level function
		#
		# Usage:
		#
		# gvm.xml_attr()
		# 
		def xml_attr(name, opts={})
			xml = REXML::Element.new(name)
			opts.keys.each do |k|
				xml.attributes[k] = opts[k]
			end
			return xml
		end

		# produce multiple XML elements with text specified as hash
		# low-level function
		#
		# Usage:
		#
		# gvm.xml_ele()
		# 
		def xml_ele(name, child={})
			xml = REXML::Element.new(name)
			child.keys.each do |k|
				xml.add_element(k)
				xml.elements[k].text = child[k]
			end
			return xml
		end

		# produce multiple XML elements with text specified as hash
		# also produce multiple XML elements with attributes
		# low-level function
		#
		# Usage:
		#
		# gvm.xml_mix()
		# 
		def xml_mix(name, child, attr, elem)
			xml = REXML::Element.new(name)
			child.keys.each do |k|
				xml.add_element(k)
				xml.elements[k].text = child[k]
			end
			elem.keys.each do |k|
				xml.add_element(k)
				xml.elements[k].attributes[attr] = elem[k]
			end
			return xml
		end

		# login to GVM server. 
		# if successful returns authentication XML for further usage
		# if unsuccessful returns empty string
		#
		# Usage:
		#
		# gvm.login()
		# 
		def login 
			areq="<authenticate>"+xml_ele("credentials", {"username"=>@user, "password"=>@password}).to_s()+"</authenticate>"
			resp=sendrecv(areq+"<HELP/>")
			# wrap it inside tags, so rexml does not cgmplain
			resp = "<X>"+resp+"</X>"

			begin
				docxml = REXML::Document.new(resp)
				status=docxml.root.elements['authenticate_response'].attributes['status'].to_i()
			rescue
				raise XMLParsingError
			end
			if status == 200
				@areq=areq
			else
				raise GMPAuthError	
			end
		end

		# check if we're successful logged in
		# if successful returns true
		# if unsuccessful returns false
		#
		# Usage:
		#
		# if gvm.logged_in() then
		# 	puts "logged in"
		# end
		#
		def logged_in
			if @areq == ''
				return false
			else
				return true
			end
		end

		# GMP low level method - Send string request wrapped with 
		# authentication XML and return response as string
		#
		# Usage:
		#
		# gvm.request_xml("<HELP/")
		# 
		def gmp_request_raw (request) 
			resp=sendrecv(@areq+request)
			return resp
		end

		# GMP low level method - Send string request wrapped with 
		# authentication XML and return REXML parsed object
		#
		# Usage:
		#
		# rexmlobject = gvm.request_xml("<HELP/")
		# 
		def gmp_request_xml (request) 
			resp=sendrecv(@areq+request)
			resp = "<X>"+resp+"</X>"

			begin
				docxml = REXML::Document.new(resp)
				status=docxml.root.elements['authenticate_response'].attributes['status'].to_i
				if status<200 and status>299
					raise GMPAuthError
				end
				return docxml.root
			rescue
				raise XMLParsingError
			end
		end

		# GMP - Create target for scanning
		#
		# Usage:
		#
		# target_id = gvm.target_create("name"=>"localhost",
		# 	"hosts"=>"127.0.0.1","comment"=>"yes")
		# 
		def target_create (p={})
			xmlreq=xml_ele("create_target", p).to_s()

			begin
				xr=gmp_request_xml(xmlreq)
				id=xr.elements['create_target_response'].attributes['id']
			rescue 
				raise GMPResponseError
			end
			return id
		end

		# GMP - Delete target 
		#
		# Usage:
		#
		# gvm.target_delete(target_id)
		# 
		def target_delete (id) 
			xmlreq=xml_attr("delete_target",{"target_id" => id}).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
			rescue 
				raise GMPResponseError
			end
			return xr
		end

		# GMP - Get target for scanning and returns rexml object
		#
		# Usage:
		# rexmlobject = target_get_raw("target_id"=>target_id)		
		# 
		def target_get_raw (p={})
			xmlreq=xml_attr("get_targets", p).to_s()

			begin
				xr=gmp_request_xml(xmlreq)
				return xr
			rescue 
				raise GMPResponseError
			end
		end

		# GMP - Get all targets for scanning and returns array of hashes
		# with following keys: id,name,comment,hosts,max_hosts,in_use
		#
		# Usage:
		# array_of_hashes = target_get_all()
		# 
		def target_get_all (p={})
			begin
				xr=target_get_raw(p)
				list=Array.new
				xr.elements.each('//get_targets_response/target') do |target|
					td=Hash.new
					td["id"]=target.attributes["id"]
					td["name"]=target.elements["name"].text
					td["comment"]=target.elements["comment"].text
					td["hosts"]=target.elements["hosts"].text
					td["max_hosts"]=target.elements["max_hosts"].text
					td["in_use"]=target.elements["in_use"].text
					list.push td
				end
				return list
			rescue 
				raise GMPResponseError
			end
		end

		def target_get_byid (id)
			begin
			xr=target_get_raw("target_id"=>id)
			xr.elements.each('//get_targets_response/target') do |target|
				td=Hash.new
				td["id"]=target.attributes["id"]
				td["name"]=target.elements["name"].text
				td["comment"]=target.elements["comment"].text
				td["hosts"]=target.elements["hosts"].text
				td["max_hosts"]=target.elements["max_hosts"].text
				td["in_use"]=target.elements["in_use"].text
				return td
			end
			return list
			rescue 
				raise GMPResponseError
			end
		end

		# GMP - get reports and returns raw rexml object as response
		#
		# Usage:
		#
		# rexmlobject=gvm.report_get_raw("format"=>"PDF")
		# 
		# rexmlobject=gvm.report_get_raw(
		#	"report_id" => "",
		#	"format"=>"PDF")
		# 
		def report_get_raw (p={})
			xmlreq=xml_attr("get_reports",p).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
			rescue 
				raise GMPResponseError
			end
			return xr
		end	

		# GMP - get report by id and format, returns report
		# (already base64 decoded if needed)
		#
		# format can be: HTML, NBE, PDF, ...	
		#
		# Usage:
		#
		# pdf_content=gvm.report_get_byid(id,"PDF")
		# File.open('report.pdf', 'w') {|f| f.write(pdf_content) }
		# 
		def report_get_byid (id,format)
			decode=Array["HTML","NBE","PDF"]
			xr=report_get_raw("report_id"=>id,"format"=>format)
			resp=xr.elements['get_reports_response'].elements['report'].text
			if decode.include?(format) 
				resp=Base64.decode64(resp)
			end
			return resp
		end

		# GMP - get report all, returns report
		#
		# Usage:
		#
		# pdf_content=gvm.report_get_all()
		# 
		def report_get_all ()
		begin
			xr=report_get_raw("format"=>"NBE")
			list=Array.new
			xr.elements.each('//get_reports_response/report') do |report|
				td=Hash.new
				td["id"]=target.attributes["id"]
				td["name"]=target.elements["name"].text
				td["comment"]=target.elements["comment"].text
				td["hosts"]=target.elements["hosts"].text
				td["max_hosts"]=target.elements["max_hosts"].text
				td["in_use"]=target.elements["in_use"].text
				list.push td
			end
			return list
		rescue 
			raise GMPResponseError
		end
		end

		# GMP - get reports and returns raw rexml object as response
		#
		# Usage:
		#
		# rexmlobject=gvm.result_get_raw("notes"=>0)
		# 
		def result_get_raw (p={})
		begin
			xmlreq=xml_attr("get_results",p).to_s()
			xr=gmp_request_xml(xmlreq)
		rescue 
			raise GMPResponseError
		end
		return xr
		end	

		# GMP - get configs and returns rexml object as response
		#
		# Usage:
		#
		# rexmldocument=gvm.config_get_raw()
		#
		def config_get_raw (p={})
			xmlreq=xml_attr("get_configs",p).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
				return xr	
			rescue 
				raise GMPResponseError
			end
			return false
		end	

		# GMP - get configs and returns hash as response
		# hash[config_id]=config_name
		#
		# Usage:
		#
		# array_of_hashes=gvm.config_get_all()
		# 
		def config_get_all (p={})
			begin
				xr=config_get_raw(p)
				tc=Array.new
				xr.elements.each('//get_configs_response/config') do |config|
					c=Hash.new
					c["id"]=config.attributes["id"]
					c["name"]=config.elements["name"].text
					c["comment"]=config.elements["comment"].text
					tc.push c
				end
				return tc
			rescue 
				raise GMPResponseError
			end
			return false
		end	

		# GMP - get configs and returns hash as response
		# hash[config_id]=config_name
		#
		# Usage:
		#
		# all_configs_hash=gvm.config.get()
		# 
		# config_id=gvm.config_get().index("Full and fast")
		# 
		def config_get (p={})
			begin
				xr=config_get_raw(p)
				list=Hash.new
				xr.elements.each('//get_configs_response/config') do |config|
					id=config.attributes["id"]
					name=config.elements["name"].text
					list[id]=name
				end
				return list	
			rescue 
				raise GMPResponseError
			end
			return false
		end	

		# GMP - copy config with new name and returns new id
		#
		# Usage:
		#
		# new_config_id=config_copy(config_id,"new_name");
		#
		def config_copy (config_id,name)
			xmlreq=xml_attr("create_config",
			{"copy"=>config_id,"name"=>name}).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
				id=xr.elements['create_config_response'].attributes['id']
				return id	
			rescue 
				raise GMPResponseError
			end
		end

		# GMP - create config with specified RC file and returns new id
		# name = name of new config
		# rcfile = base64 encoded GVM rcfile
		#
		# Usage:
		#
		# config_id=config_create("name",rcfile);
		#
		def config_create (name,rcfile)
			xmlreq=xml_attr("create_config",
			{"name"=>name,"rcfile"=>rcfile}).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
				id=xr.elements['create_config_response'].attributes['id']
				return id	
			rescue 
				raise GMPResponseError
			end
		end

		# GMP - creates task and returns id of created task
		#
		# Parameters which usually fit in p hash and i hash:
		# p = name,comment,rcfile
		# i = config,target,escalator,schedule
		#
		# Usage:
		#
		# task_id=gvm.task_create_raw()
		# 
		def task_create_raw (p={}, i={}) 
			xmlreq=xml_mix("create_task",p,"id",i).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
				id=xr.elements['create_task_response'].attributes['id']
				return id
			rescue 
				raise GMPResponseError
			end
		end

		# GMP - creates task and returns id of created task	
		# 
		# parameters = name,comment,rcfile,config,target,escalator,
		#		schedule
		#
		# Usage:
		#
		# config_id=o.config_get().index("Full and fast")
		# target_id=o.target_create(
		# {"name"=>"localtarget", "hosts"=>"127.0.0.1", "comment"=>"t"})
		# task_id=gvm.task_create(
		# {"name"=>"testlocal","comment"=>"test", "target"=>target_id, 
		# "config"=>config_id}
		# 
		def task_create (p={}) 
			specials=Array["config","target","escalator","schedule"]	
			ids = Hash.new
			specials.each do |spec|
				if p.has_key?(spec)
					ids[spec]=p[spec]	
					p.delete(spec)
				end	
			end
			return task_create_raw(p,ids)
		end

		# GMP - deletes task specified by task_id
		# 
		# Usage:
		#
		# gvm.task_delete(task_id)
		# 
		def task_delete (task_id) 
			xmlreq=xml_attr("delete_task",{"task_id" => task_id}).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
			rescue 
				raise GMPResponseError
			end
			return xr
		end

		# GMP - get task and returns raw rexml object as response
		#
		# Usage:
		#
		# rexmlobject=gvm.task_get_raw("details"=>"0")
		# 
		def task_get_raw (p={}) 
			xmlreq=xml_attr("get_tasks",p).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
				return xr
			rescue 
				raise GMPResponseError
			end
		end

		# GMP - get all tasks and returns array with hashes with 
		# following content:
		# id,name,comment,status,progress,first_report,last_report
		#
		# Usage:
		#
		# array_of_hashes=gvm.task_get_all()
		# 
		def task_get_all (p={}) 
			xr=task_get_raw(p)
			t=Array.new
			xr.elements.each('//get_tasks_response/task') do |task|
				td=Hash.new
				td["id"]=task.attributes["id"]
				td["name"]=task.elements["name"].text
				td["comment"]=task.elements["comment"].text
				td["status"]=task.elements["status"].text
				td["progress"]=task.elements["progress"].text
				if defined? task.elements["first_report"].elements["report"].attributes["id"] then
				td["firstreport"]=task.elements["first_report"].elements["report"].attributes["id"]
				else
					td["firstreport"]=nil
				end
				if defined? task.elements["last_report"].elements["report"].attributes["id"] then
				td["lastreport"]=task.elements["last_report"].elements["report"].attributes["id"] 
				else
					td["lastreport"]=nil
				end
				t.push td	
			end
			return t
		end

		# GMP - get task specified by task_id and returns hash with 
		# following content:
		# id,name,comment,status,progress,first_report,last_report
		#
		# Usage:
		#
		# hash=gvm.task_get_byid(task_id)
		# 
		def task_get_byid (id) 
			xr=task_get_raw("task_id"=>id,"details"=>0)
			xr.elements.each('//get_tasks_response/task') do |task|
				td=Hash.new
				td["id"]=task.attributes["id"]
				td["name"]=task.elements["name"].text
				td["comment"]=task.elements["comment"].text
				td["status"]=task.elements["status"].text
				td["progress"]=task.elements["progress"].text
				if defined? task.elements["first_report"].elements["report"].attributes["id"] then
				td["firstreport"]=task.elements["first_report"].elements["report"].attributes["id"]
				else
					td["firstreport"]=nil
				end
				if defined? task.elements["last_report"].elements["report"].attributes["id"] then
				td["lastreport"]=task.elements["last_report"].elements["report"].attributes["id"] 
				else
					td["lastreport"]=nil
				end
				return (td)
			end
		end

		# GMP - check if task specified by task_id is finished 
		# (it checks if task status is "Done" in GMP)
		# 
		# Usage:
		#
		# if gvm.task_finished(task_id)
		#	puts "Task finished"
		# end
		# 
		def task_finished (id) 
			xr=task_get_raw("task_id"=>id,"details"=>0)
			xr.elements.each('//get_tasks_response/task') do |task|
				if status=task.elements["status"].text == "Done"
					return true
				else
					return false
				end
			end
		end

		# GMP - check progress of task specified by task_id 
		# (GMP returns -1 if task is finished, not started, etc)
		# 
		# Usage:
		#
		# print "Progress: "
		# puts gvm.task_progress(task_id)
		# 
		def task_progress (id) 
			xr=task_get_raw("task_id"=>id,"details"=>0)
			xr.elements.each('//get_tasks_response/task') do |task|
				return task.elements["progress"].text.to_i()
			end
		end

		# GMP - starts task specified by task_id 
		# 
		# Usage:
		#
		# gvm.task_start(task_id)
		# 
		def task_start (task_id) 
			xmlreq=xml_attr("start_task",{"task_id" => task_id}).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
			rescue 
				raise GMPResponseError
			end
			return xr
		end

		# GMP - stops task specified by task_id 
		# 
		# Usage:
		#
		# gvm.task_stop(task_id)
		# 
		def task_stop (task_id) 
			xmlreq=xml_attr("stop_task",{"task_id" => task_id}).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
			rescue 
				raise GMPResponseError
			end
			return xr
		end

		# GMP - pauses task specified by task_id 
		# 
		# Usage:
		#
		# gvm.task_pause(task_id)
		# 
		def task_pause (task_id)
			xmlreq=xml_attr("pause_task",{"task_id" => task_id}).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
			rescue 
				raise GMPResponseError
			end
			return xr
		end

		# GMP - resumes (or starts) task specified by task_id 
		# 
		# Usage:
		#
		# gvm.task_resume_or_start(task_id)
		# 
		def task_resume_or_start (task_id)
			xmlreq=xml_attr("resume_or_start_task",{"task_id" => task_id}).to_s()
			begin
				xr=gmp_request_xml(xmlreq)
			rescue 
				raise GMPResponseError
			end
			return xr
		end

	end # end of Class

end # of Module


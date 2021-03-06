#!/usr/bin/env ruby

require 'rubygems'
require 'activerecord'
require 'net/smtp'
require 'rmail'
require 'tlsmail'
require 'yaml'

config = YAML.load_file(File.dirname(__FILE__) + "/config.yml")

ActiveRecord::Base.establish_connection(
  :adapter  => "activesalesforce",
  :url      => config['salesforce_url'],
  :username => config['salesforce_user'],
  :password => config['salesforce_password']
)

class Contact < ActiveRecord::Base
end

class Account < ActiveRecord::Base
end

class Case < ActiveRecord::Base
end

def id_to_url(s)
  s = s[0,s.length-3]
#  "#{config['salesforce_base_url']}/#{s}"
  "https://na5.salesforce.com/#{s}"
end

def lookup_account(p)
  begin
    Account.find_by_phone(p)
  rescue Exception => e
#    print "Error - #{e.to_s}\n"
  end
  a = Account.find_by_phone(p)
  a = Account.find_by_fax(p) if a.nil?
  return a
end

def lookup_contact(p)
  begin
    Contact.find_by_phone(p)
  rescue Exception => e
#    print "Error - #{e.to_s}\n"
  end
  c = Contact.find_by_phone(p)
  c = Contact.find_by_fax(p) if c.nil?
  c = Contact.find_by_mobile_phone(p) if c.nil?
  c = Contact.find_by_home_phone(p) if c.nil?
  c = Contact.find_by_other_phone(p) if c.nil?
  c = Contact.find_by_assistant_phone(p) if c.nil?
  return c
end

def lookup_phone(p)
  result = "";
  begin
    a = lookup_account(p)
    c = lookup_contact(p)
    if a.nil? && c.nil? == false
      a = Account.find_by_id(c.account_id)
    end

    if c.nil? == false
#      print "Contact ID is #{c.id}\n"
      begin
        Case.find(:all, :conditions => {:contact_id=>c.id, :is_closed=>false})
      rescue Exception => e
#        print "Error - #{e.to_s}\n"
      end
      cases = Case.find(:all, :conditions => {:contact_id=>c.id, :is_closed=>false})

      result += "Contact for #{p} is #{c.name} (#{cases.length} open cases) - #{id_to_url(c.id)}\n"
    end
    if a.nil? == false
#      print "Account ID is #{a.id}\n"
      begin
        Case.find(:all, :conditions => {:account_id=>a.id, :is_closed=>false})
      rescue Exception => e
#        print "Error - #{e.to_s}\n"
      end
      cases = Case.find(:all, :conditions => {:account_id=>a.id, :is_closed=>false})

      result += "Account for #{p} is #{a.name} (#{cases.length} open cases) - #{id_to_url(a.id)}\n"
    end
  rescue Exception => e
    result += "Can't find #{p} in SalesForce - #{e.to_s}\n"
  end
  
  result = "Can't find #{p} in SalesForce\n" if result.empty?
  return result
end

message = RMail::Parser.read(STDIN)

if message.multipart? == false
	exit
end

email = message.header.to.format
output = nil;
callDate = message.header.date.strftime('%I:%M%p %m/%d/%Y') 
callerName = message.header.subject[12..message.header.subject.length]
callerID = 'unknown'
if callerName =~ /(\d{10})/
  callerID = $1
  callerID = "(#{callerID[0,3]}) #{callerID[3,3]}-#{callerID[6,4]}"
end

message.body.each { |part|
	if part.header['Content-Type'] =~ /^audio\//
		path = "#{config['temp_dir']}/vmail#{$$}.wav"
		pathtmp = "#{config['temp_dir']}/vmailx#{$$}.wav"
		output = "#{config['temp_dir']}/vmail#{$$}.mp3"
		f = File.new(path, 'w')
		f.write(part.decode)
		f.close

		system "#{config['sox_path']} #{path} -u #{pathtmp}"
		File.delete(path)

		system "#{config['lame_path']} --preset voice -v -q 0 -V 9 --tl Voicemail --ta Voicemail --tt \"Call from #{callerName} at #{callDate}\" --tg 28 --quiet #{pathtmp} #{output}"
		File.delete(pathtmp)
	end
}

if output == nil
	exit
end

# send email
mail = RMail::Message.new
mail.header.from = "Voicemail <#{config['processed_from_address']}>"
mail.header.to = email
mail.header.subject = "Voicemail from #{callerName} at #{callDate}"

content = RMail::Message::new
content.header.set('Content-Type', 'text/plain',
        'charset' => 'us-ascii')
content.header.set('Content-Disposition', 'inline')
content.body = "You received a voicemail from #{callerName} at #{callDate}\n\n"
content.body += lookup_phone(callerID)
mail.add_part(content)

part = RMail::Message::new
part.header.set('Content-Type', 'audio/mpeg')
part.header.set('Content-Disposition',
        'attachment',
        'filename' => "Voicemail-#{callerID}-#{callDate}.mp3")
part.header.set('Content-Transfer-Encoding', 'base64')
File::open(output) do |fh|
  part.body = fh.sysread(File::size(output)).unpack('a*').pack('m')
end
mail.add_part(part)

#print "Sending email to #{email}...\n"

if config['use_smtp']
  Net::SMTP.enable_tls(OpenSSL::SSL::VERIFY_NONE) if config['use_smtp_ssl']
  Net::SMTP.start(config['smtp_server'], config['smtp_port'], config['smtp_domain'], config['processed_from_address'], config['smtp_password'], :login) do |smtp|
  smtp.send_message(mail, config['processed_from_address'], email)
  end
else
  IO.popen("#{config['sendmail_path']} #{email}", "w") do |sendmail|
    sendmail.print mail
  end
end

File.delete(output)

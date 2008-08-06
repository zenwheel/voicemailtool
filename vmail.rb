#!/usr/bin/env ruby

require 'rubygems'
require 'net/smtp'
require 'rmail'

message = RMail::Parser.read(STDIN)

if message.multipart? == false
	exit
end

source = 'voicemail@wheelshit.com'
email = message.header.to.format
output = nil;
callDate = message.header.date.strftime('%I:%M%p %m/%d/%Y') 
callerID = message.header.from[0].local
if callerID =~ /^\d{10}$/
	callerID = callerID[0,3] + '-' + callerID[3,3] + '-' + callerID[6,4]
end

message.body.each { |part|
	if part.header['Content-Type'] =~ /^audio\//
		path = '/tmp/vmail' + $$.to_s + '.wav'
		output = '/tmp/vmail' + $$.to_s + '.mp3'
		f = File.new(path, 'w')
		f.write(part.decode)
		f.close

		system '/usr/local/bin/lame --preset phone -v -q 0 -V 9 --tl Voicemail --ta Voicemail --tt "Call from ' + callerID + ' at ' + callDate + '" --tg 28 --quiet ' + path + ' ' + output
		File.delete(path)
	end
}

if output == nil
	exit
end

# send email
mail = RMail::Message.new
mail.header.from = "Voicemail <" + source + ">"
mail.header.to = email
mail.header.subject = "Voicemail from " + callerID + " at " + callDate

content = RMail::Message::new
content.header.set('Content-Type', 'text/plain',
        'charset' => 'us-ascii')
content.header.set('Content-Disposition', 'inline')
content.body = "You received a voicemail from " + callerID + " at " + callDate
mail.add_part(content)

part = RMail::Message::new
part.header.set('Content-Type', 'audio/mpeg')
part.header.set('Content-Disposition',
        'attachment',
        'filename' => 'Voicemail-' + callerID + '.mp3')
part.header.set('Content-Transfer-Encoding', 'base64')
File::open(output) do |fh|
  part.body = fh.sysread(File::size(output)).unpack('a*').pack('m')
end
mail.add_part(part)

IO.popen("/usr/sbin/sendmail #{email}", "w") do |sendmail|
  sendmail.print mail
end

File.delete(output)

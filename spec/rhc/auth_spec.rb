require 'spec_helper'
require 'base64'
require 'rhc/commands'

describe RHC::Auth::Basic do
  let(:user){ 'test_user' }
  let(:password){ 'test pass' }
  let(:auth_hash){ {:user => user, :password => password} }
  let(:options){ (o = Commander::Command::Options.new).default(default_options); o }
  let(:default_options){ {} }
  let(:client){ double(:supports_sessions? => false) }

  its(:username){ should be_nil }
  its(:username?){ should be_false }
  its(:password){ should be_nil }
  its(:options){ should_not be_nil }
  its(:can_authenticate?){ should be_false }
  its(:openshift_server){ should == 'openshift.redhat.com' }
  its( :expired_token_message) { should == "Your authorization token has expired. Please sign in now to continue on #{subject.openshift_server}." }
  its( :get_token_message) { should == "Please sign in to start a new session to #{subject.openshift_server}." }

  def resolved(hash)
    hash.each_pair do |k,v|
      hash[k] = v.call if v.is_a? Proc
    end
    hash
  end

  context "with user options" do
    subject{ described_class.new(options) }

    its(:username){ should be_nil }
    its(:username?){ should be_false }
    its(:password){ should be_nil }
    its(:options){ should equal(options) }

    context "that include user info" do
      let(:default_options){ {:rhlogin => user, :password => password} }

      its(:username){ should == user }
      its(:username?){ should be_true }
      its(:password){ should == password }
      its(:can_authenticate?){ should be_true }
    end

    context "that includes server" do
      let(:default_options){ {:server => 'test.com'} }

      its(:openshift_server){ should == 'test.com' }
      it do
        subject.should_receive(:ask).with("Login to test.com: ").and_return(user)
        subject.send(:ask_username).should == user
      end
    end

    context "with --noprompt" do
      let(:default_options){ {:noprompt => true} }

      its(:ask_username){ should be_false }
      its(:ask_password){ should be_false }
      its(:username?){ should be_false }
      it("should not retry") do 
        subject.should_not_receive(:ask_username)
        subject.retry_auth?(double(:status => 401), client).should be_false
      end
    end
  end

  context "when initialized with a hash" do
    subject{ described_class.new({:rhlogin => user, :password => password}) }
    its(:username){ should == user }
    its(:password){ should == password }
  end


  describe "#ask_username" do
    before{ subject.should_receive(:openshift_server).and_return('test.com') }
    before{ subject.should_receive(:ask).with("Login to test.com: ").and_return(user) }

    it do
      subject.send(:ask_username).should == user
      subject.send(:username).should == user
    end

    context "with a different user" do
      subject{ described_class.new('other', nil) }
      it do
        subject.send(:ask_username).should == user
        subject.send(:username).should == user
      end
    end
  end

  describe "#ask_password" do
    before{ subject.should_receive(:ask).with("Password: ").and_return(password) }
    it do
      subject.send(:ask_password).should == password
      subject.send(:password).should == password
    end

    context "with a different password" do
      subject{ described_class.new(user, 'other') }
      it do
        subject.send(:ask_password).should == password
        subject.send(:password).should == password
      end
    end
  end

  describe "#to_request" do
    let(:request){ {} }

    context "when the request is lazy" do
      let(:request){ {:lazy_auth => true} }
      before{ subject.should_receive(:ask_username).never }
      before{ subject.should_receive(:ask_password).never }

      it { subject.to_request(request).should == request }
    end

    context "when password and user are provided" do
      subject{ described_class.new(user, password) }

      it { subject.to_request(request).should equal(request) }
      it { resolved(subject.to_request(request)).should == auth_hash }

      context "when the request is lazy" do
        let(:request){ {:lazy_auth => true} }

        it { subject.to_request(request).should == auth_hash.merge(request) }
      end
    end

    context "when password is not provided" do
      subject{ described_class.new(user, nil) }

      its(:password){ should be_nil }
      it "should ask for the password" do
        subject.should_receive(:ask_password).and_return(password)
        resolved(subject.to_request(request)).should == auth_hash
      end
      it "should remember the password" do
        subject.should_receive(:ask_password).and_return(password)
        subject.to_request(request)
        resolved(subject.to_request(request)).should == auth_hash
      end

      context "when the request is lazy" do
        let(:request){ {:lazy_auth => true} }
        before{ subject.should_receive(:ask_password).never }

        it { subject.to_request(request).should == auth_hash.merge(request) }
      end
    end

    context "when user is not provided" do
      subject{ described_class.new(nil, password) }

      its(:username){ should be_nil }
      it "should ask for the username" do
        subject.should_receive(:ask_username).and_return(user)
        resolved(subject.to_request(request)).should == auth_hash
      end
      it "should remember the username" do
        subject.should_receive(:ask_username).and_return(user)
        subject.to_request(request)
        resolved(subject.to_request(request)).should == auth_hash
      end

      context "when the request is lazy" do
        let(:request){ {:lazy_auth => true} }
        before{ subject.should_receive(:ask_username).never }

        it { subject.to_request(request).should == auth_hash.merge(request) }
      end
    end
  end

  describe "#retry_auth?" do
    context "when the response succeeds" do
      let(:response){ double(:cookies => {}, :status => 200) }

      it{ subject.retry_auth?(response, client).should be_false }
    end
    context "when the response succeeds with a cookie" do
      let(:response){ double(:cookies => [double(:name => 'rh_sso', :value => '1')], :status => 200) }
      it{ subject.retry_auth?(response, client).should be_false }
    end
    context "when the response requires authentication" do
      let(:response){ double(:status => 401) }

      context "with no user and no password" do
        subject{ described_class.new(nil, nil) }
        it("should ask for user and password") do
          subject.should_receive(:ask_username).and_return(user)
          subject.should_receive(:ask_password).and_return(password)
          subject.retry_auth?(response, client).should be_true
        end
      end

      context "with user and no password" do
        subject{ described_class.new(user, nil) }
        it("should ask for password only") do
          subject.should_receive(:ask_password).and_return(password)
          subject.retry_auth?(response, client).should be_true
        end
        it("should ask for password twice") do
          subject.should_receive(:ask_password).twice.and_return(password)
          subject.retry_auth?(response, client).should be_true
          subject.retry_auth?(response, client).should be_true
        end
      end

      context "with user and password" do
        subject{ described_class.new(user, password) }
        it("should not prompt for reauthentication") do
          subject.should_not_receive(:ask_password)
          subject.should_receive(:error).with("Username or password is not correct")
          subject.retry_auth?(response, client).should be_false
        end
      end
    end
  end
end

describe RHC::Auth::X509 do
  subject{ described_class.new(options) }

  let(:default_options){ {} }
  let(:options){ (o = Commander::Command::Options.new).default(default_options); o }
  let(:a_cert){ OpenSSL::X509::Certificate.new }
  let(:a_key){ OpenSSL::PKey::RSA.new }
  its(:options){ should_not be_nil }
  its(:can_authenticate?){ should be_true }
  its(:openshift_server){ should == 'openshift.redhat.com' }
  its(:expired_token_message) { should == "Your authorization token has expired.  Fetching a new token from #{subject.openshift_server}."}
  its(:get_token_message) { should == "Fetching a new token from #{subject.openshift_server}." }

  describe "#retry_auth?" do
    context "should return true if the response was 401" do
      let(:response){ double(:status => 401) }
      let(:client){ double }
      it { subject.retry_auth?(response, client).should == true }
    end

    context "should return false if the response was 403" do
      let(:response){ double }
      let(:client){ double }
      let(:response){ double(:status => 403) }
      it { subject.retry_auth?(response, client).should == false }
    end
  end

  describe "#to_request" do
    let(:request){ {} }
    let(:auth_hash){ {:client_cert => a_cert, :client_key => a_key} }

    context "when a certificate exists" do
      it "should use x509 auth" do
        OpenSSL::X509::Certificate.should_receive(:new).exactly(1).times.and_return(a_cert)
        OpenSSL::PKey::RSA.should_receive(:new).exactly(1).times.and_return(a_key)
        subject.to_request(request).should == auth_hash
      end
    end

    context "when a certificate can't be loaded" do
      it "should send a debug message and raise an error" do
        options.should_receive(:ssl_client_cert_file).and_return("a bogus path")
        subject.should_receive(:debug)
        expect do
          subject.to_request(request)
        end.to raise_error
      end
    end

    context "when a key can't be loaded" do
      it "should send a debug message and raise an error" do
        options.should_receive(:ssl_client_key_file).and_return("a bogus path")
        subject.should_receive(:debug)
        expect do
          subject.to_request(request)
        end.to raise_error
      end
    end
  end
end

describe RHC::Auth::Token do
  subject{ described_class.new(options) }

  let(:token){ 'a_token' }
  let(:options){ (o = Commander::Command::Options.new).default(default_options); o }
  let(:default_options){ {} }
  let(:client){ double(:supports_sessions? => false) }
  let(:auth){ nil }
  let(:store){ nil }

  its(:username){ should be_nil }
  its(:options){ should_not be_nil }
  its(:can_authenticate?){ should be_false }
  its(:openshift_server){ should == 'openshift.redhat.com' }

  context "with user options" do
    its(:username){ should be_nil }
    its(:options){ should equal(options) }

    context "that include token" do
      let(:default_options){ {:token => token} }
      its(:can_authenticate?){ should be_true }
    end

    context "that includes server" do
      let(:default_options){ {:server => 'test.com'} }
      its(:openshift_server){ should == 'test.com' }
    end

    context "with --noprompt" do
      let(:default_options){ {:noprompt => true} }

      its(:username){ should be_nil }
      it("should not retry") do 
      end
    end
  end

  context "when initialized with a hash" do
    subject{ described_class.new({:token => token}) }
    its(:token){ should == token }
  end

  context "when initialized with a string" do
    subject{ described_class.new(token) }
    its(:token){ should == token }
  end

  context "when initialized with an auth object" do
    subject{ described_class.new(nil, auth) }
    let(:auth){ double(:username => 'foo') }
    its(:username){ should == 'foo' }
  end

  context "when initialized with a store" do
    subject{ described_class.new(nil, nil, store) }
    let(:store){ double }
    before{ store.should_receive(:get).with(nil, 'openshift.redhat.com').and_return(token) }
    it("should read the token for the user") do
      subject.send(:token).should == token
    end
  end

  describe "#save" do
    subject{ described_class.new(nil, nil, store) }
    context "when store is set" do
      let(:store){ double(:get => nil) }
      it("should call put on store") do
        subject.should_receive(:username).and_return('foo')
        subject.should_receive(:openshift_server).and_return('bar')
        store.should_receive(:put).with('foo', 'bar', token)
        subject.save(token)
      end
    end
    context "when store is nil" do
      it("should skip calling store"){ subject.save(token) }
    end
    after{ subject.instance_variable_get(:@token).should == token }
  end

  describe "#to_request" do
    let(:request){ {} }
    subject{ described_class.new(token, auth) }

    context "when token is provided" do
      it("should pass bearer token to the server"){ subject.to_request(request).should == {:headers => {'authorization' => "Bearer #{token}"}} }

      context "when the request is lazy" do
        let(:request){ {:lazy_auth => true} }
        it("should pass bearer token to the server"){ subject.to_request(request).should == {:lazy_auth => true, :headers => {'authorization' => "Bearer #{token}"}} }
      end
    end

    context "when token is not provided" do
      subject{ described_class.new(nil) }

      it("should submit an empty bearer token to the server to trigger the 401 retry flow for OpenShift Enterprise"){ subject.to_request(request).should == {:headers => {'authorization' => "Bearer "}} }
    end

    context "when a parent auth class is passed" do
      subject{ described_class.new(nil, auth) }
      let(:auth){ double }
      it("should invoke the parent") do
        auth.should_receive(:to_request).with(request).and_return(request)
        subject.to_request(request).should == request
      end
    end
  end

  describe "#retry_auth?" do
    subject{ described_class.new(token, auth) }

    context "when the response succeeds" do
      let(:response){ double(:cookies => {}, :status => 200) }
      it{ subject.retry_auth?(response, client).should be_false }
    end

    context "when the response requires authentication" do
      let(:response){ double(:status => 401) }

      context "with no token" do
        subject{ described_class.new(nil, nil) }
        it("should return false"){ subject.retry_auth?(response, client).should be_false }
      end

      context "when a nested auth object can't authenticate" do
        let(:auth){ double(:can_authenticate? => false) }
        it("should raise an error"){ expect{ subject.retry_auth?(response, client) }.to raise_error(RHC::Rest::TokenExpiredOrInvalid) }
      end

      context "with a nested auth object" do
        let(:auth){ double('nested_auth', :can_authenticate? => true) }
        subject{ described_class.new(options, auth) }

        it("should not use token auth") do 
          auth.should_receive(:retry_auth?).with(response, client).and_return true
          subject.retry_auth?(response, client).should be_true
        end

        context "when noprompt is requested" do
          let(:default_options){ {:token => token, :noprompt => true} }
          it("should raise an error"){ expect{ subject.retry_auth?(response, client) }.to raise_error(RHC::Rest::TokenExpiredOrInvalid) }
        end

        context "when authorization tokens are enabled locally" do
          let(:default_options){ {:use_authorization_tokens => true} }

          context "without session support" do
            let(:default_options){ {:use_authorization_tokens => true, :token => 'foo'} }
            let(:client){ double('client', :supports_sessions? => false) }

            it("should invoke raise an error on retry because sessions are not supported") do
              expect{ subject.retry_auth?(response, client) }.to raise_error RHC::Rest::AuthorizationsNotSupported
            end
          end

          context "we expect a warning and a call to client" do
            let(:auth_token){ nil }
            let(:client){ double('client', :supports_sessions? => true) }
            before{ client.should_receive(:new_session).with(:auth => auth).and_return(auth_token) }

            it("should print a message") do 
              subject.should_receive(:info).with("get token message")
              auth.should_receive(:retry_auth?).with(response, client).and_return true
              auth.should_receive(:get_token_message).and_return("get token message")
              subject.retry_auth?(response, client).should be_true
            end

            context "with a token" do
              let(:default_options){ {:use_authorization_tokens => true, :token => 'foo'} }
              it("should invoke raise an error on retry because sessions are not supported") do
                subject.should_receive(:warn).with("expired token message")
                auth.should_receive(:retry_auth?).with(response, client).and_return true
                auth.should_receive(:expired_token_message).and_return("expired token message")
                subject.retry_auth?(response, client).should be_true
                #expect{ subject.retry_auth?(response, client) }.to raise_error RHC::Rest::AuthorizationsNotSupported
              end
            end

            context "when the token request fails" do
              before do
                subject.should_receive(:info).with("get token message")
                auth.should_receive(:get_token_message).and_return("get token message")
              end
              it("should invoke retry on the parent") do
                auth.should_receive(:retry_auth?).with(response, client).and_return false
                subject.retry_auth?(response, client).should be_false
              end
            end

            context "when the token request succeeds" do
              let(:auth_token){ double('auth_token', :token => 'bar') }
              before do
                subject.should_receive(:info).with("get token message")
                auth.should_receive(:get_token_message).and_return("get token message")
              end
              it("should save the token and return true") do
                subject.should_receive(:save).with(auth_token.token).and_return true
                subject.retry_auth?(response, client).should be_true
              end
            end
          end
        end
      end
    end
  end
end

describe RHC::Auth::TokenStore do
  subject{ described_class.new(dir) }
  let(:dir){ Dir.mktmpdir }

  context "when a key is stored" do
    before{ subject.put('foo', 'bar', 'token') }
    it("can be retrieved"){ subject.get('foo', 'bar').should == 'token' }
  end

  it("should handle missing files"){ subject.get('foo', 'other').should be_nil }
  it("should put a file on disk"){ expect{ subject.put('test', 'server', 'value') }.to change{ Dir.entries(dir).length }.by(1) }

  describe "#clear" do
    before{ subject.put('test', 'server2', 'value2') }
    it("should return true"){ subject.clear.should be_true }
    it("should empty the directory"){ expect{ subject.clear }.to change{ Dir.entries(dir).length }.by_at_least(-1) }
    after{ Dir.entries(dir).length.should == 2 }
  end
end

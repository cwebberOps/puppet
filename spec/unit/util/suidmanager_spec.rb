#!/usr/bin/env rspec

require 'spec_helper'

describe Puppet::Util::SUIDManager do
  let :user do
    Puppet::Type.type(:user).new(:name => 'name', :uid => 42, :gid => 42)
  end

  let :xids do
    Hash.new {|h,k| 0}
  end

  before :each do
    Puppet::Util::SUIDManager.stubs(:convert_xid).returns(42)
    Puppet::Util::SUIDManager.stubs(:initgroups)

    [:euid, :egid, :uid, :gid, :groups].each do |id|
      Process.stubs("#{id}=").with {|value| xids[id] = value}
    end
  end

  describe "#uid" do
    it "should allow setting euid/egid" do
      Puppet::Util::SUIDManager.egid = user[:gid]
      Puppet::Util::SUIDManager.euid = user[:uid]

      xids[:egid].should == user[:gid]
      xids[:euid].should == user[:uid]
    end
  end

  describe "#asuser" do
    it "should set euid/egid when root" do
      Process.stubs(:uid).returns(0)

      Process.stubs(:egid).returns(51)
      Process.stubs(:euid).returns(50)

      Puppet::Util::SUIDManager.stubs(:convert_xid).with(:gid, 51).returns(51)
      Puppet::Util::SUIDManager.stubs(:convert_xid).with(:uid, 50).returns(50)

      yielded = false
      Puppet::Util::SUIDManager.asuser(user[:uid], user[:gid]) do
        xids[:egid].should == user[:gid]
        xids[:euid].should == user[:uid]
        yielded = true
      end

      xids[:egid].should == 51
      xids[:euid].should == 50

      # It's possible asuser could simply not yield, so the assertions in the
      # block wouldn't fail. So verify those actually got checked.
      yielded.should be_true
    end

    it "should not get or set euid/egid when not root" do
      Process.stubs(:uid).returns(1)

      Process.stubs(:egid).returns(51)
      Process.stubs(:euid).returns(50)

      Puppet::Util::SUIDManager.asuser(user[:uid], user[:gid]) {}

      xids.should be_empty
    end
  end

  describe "#change_group" do
    describe "when changing permanently" do
      it "should try to change_privilege if it is supported" do
        Process::GID.expects(:change_privilege).with do |gid|
          Process.gid = gid
          Process.egid = gid
        end

        Puppet::Util::SUIDManager.change_group(42, true)

        xids[:egid].should == 42
        xids[:gid].should == 42
      end

      it "should change both egid and gid if change_privilege isn't supported" do
        Process::GID.stubs(:change_privilege).raises(NotImplementedError)

        Puppet::Util::SUIDManager.change_group(42, true)

        xids[:egid].should == 42
        xids[:gid].should == 42
      end
    end

    describe "when changing temporarily" do
      it "should change only egid" do
        Puppet::Util::SUIDManager.change_group(42, false)

        xids[:egid].should == 42
        xids[:gid].should == 0
      end
    end
  end

  describe "#change_user" do
    describe "when changing permanently" do
      it "should try to change_privilege if it is supported" do
        Process::UID.expects(:change_privilege).with do |uid|
          Process.uid = uid
          Process.euid = uid
        end

        Puppet::Util::SUIDManager.change_user(42, true)

        xids[:euid].should == 42
        xids[:uid].should == 42
      end

      it "should change euid and uid and groups if change_privilege isn't supported" do
        Process::UID.stubs(:change_privilege).raises(NotImplementedError)

        Puppet::Util::SUIDManager.expects(:initgroups).with(42)

        Puppet::Util::SUIDManager.change_user(42, true)

        xids[:euid].should == 42
        xids[:uid].should == 42
      end
    end

    describe "when changing temporarily" do
      it "should change only euid and groups" do
        Puppet::Util::SUIDManager.change_user(42, false)

        xids[:euid].should == 42
        xids[:uid].should == 0
      end
    end
  end

  describe "when running commands" do
    before :each do
      # We want to make sure $CHILD_STATUS is set
      Kernel.system '' if $CHILD_STATUS.nil?
    end

    describe "with #system" do
      it "should set euid/egid when root" do
        Process.stubs(:uid).returns(0)
        Process.stubs(:egid).returns(51)
        Process.stubs(:euid).returns(50)

        Puppet::Util::SUIDManager.stubs(:convert_xid).with(:gid, 51).returns(51)
        Puppet::Util::SUIDManager.stubs(:convert_xid).with(:uid, 50).returns(50)

        Puppet::Util::SUIDManager.expects(:change_group).with(user[:uid])
        Puppet::Util::SUIDManager.expects(:change_user).with(user[:uid])

        Puppet::Util::SUIDManager.expects(:change_group).with(51)
        Puppet::Util::SUIDManager.expects(:change_user).with(50)

        Kernel.expects(:system).with('blah')
        Puppet::Util::SUIDManager.system('blah', user[:uid], user[:gid])
      end

      it "should not get or set euid/egid when not root" do
        Process.stubs(:uid).returns(1)
        Kernel.expects(:system).with('blah')

        Puppet::Util::SUIDManager.system('blah', user[:uid], user[:gid])

        xids.should be_empty
      end
    end

    describe "with #run_and_capture" do
      it "should capture the output and return process status" do
        Puppet::Util.
          expects(:execute).
          with('yay', :combine => true, :failonfail => false, :uid => user[:uid], :gid => user[:gid]).
          returns('output')
        output = Puppet::Util::SUIDManager.run_and_capture 'yay', user[:uid], user[:gid]

        output.first.should == 'output'
        output.last.should be_a(Process::Status)
      end
    end
  end
end
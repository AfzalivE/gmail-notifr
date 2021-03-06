#
#  ApplicationController.rb
#  Gmail Notifr
#
#  Created by james on 10/3/08.
#  Copyright (c) 2008 ashchan.com. All rights reserved.
#


class ApplicationController
  KInternetEventClass = KAEGetURL = 'GURL'.unpack('N').first
  KeyDirectObject = '----'.unpack('N').first

  ACCOUNT_MENUITEM_POS = 2
  CHECK_MENUITEM_POS = 1
  ENABLE_MENUITEM_POS = 2
  DEFAULT_ACCOUNT_SUBMENU_COUNT = 4
  DONATE_URL = "http://www.pledgie.com/campaigns/2046"

  attr_accessor :menu

  def awakeFromNib
    @status_bar = NSStatusBar.systemStatusBar
    @status_item = @status_bar.statusItemWithLength(NSVariableStatusItemLength)
    @status_item.setHighlightMode(true)
    @status_item.setMenu(@menu)

    @app_icon = NSImage.imageNamed('app.tiff')
    @app_alter_icon = NSImage.imageNamed('app_a.tiff')
    @mail_icon = NSImage.imageNamed('mail.tiff')
    @mail_alter_icon = NSImage.imageNamed('mail_a.tiff')
    @check_icon = NSImage.imageNamed('check.tiff')
    @check_alter_icon = NSImage.imageNamed('check_a.tiff')
    @error_icon = NSImage.imageNamed('error.tiff')

    @status_item.setImage(@app_icon)
    @status_item.setAlternateImage(@app_alter_icon)

    GNPreferences::setupDefaults

    registerObservers

    registerMailtoHandler

    registerGrowl

    setupMenu

    setupCheckers
  end

  def openInbox(sender)
    if sender.title == NSLocalizedString("Open Inbox")
      # "Open Inbox" menu item
      account = accountForGuid(sender.menu.title)
    else
      # top menu item for account
      account = accountForGuid(sender.submenu.title)
    end
    openInboxForAccount(account)
  end

  def toggleAccount(sender)
    account = accountForGuid(sender.menu.title)
    account.enabled = !account.enabled
    account.save

    updateMenuItemAccountEnabled(account)
    checkerForAccount(account).reset
  end

  def openURL(url, browserIdentifier = GNBrowser::DEFAULT)
    nsurl = NSURL.URLWithString(url)
    unless GNBrowser.default?(browserIdentifier)
      NSWorkspace.sharedWorkspace.openURLs([nsurl],
                                           withAppBundleIdentifier: browserIdentifier,
                                           options: NSWorkspaceLaunchDefault,
                                           additionalEventParamDescriptor:nil,
                                           launchIdentifiers:nil)
    else
      NSWorkspace.sharedWorkspace.openURL(nsurl)
    end
  end

  def openMessage(sender)
    openURL(sender.representedObject, GNAccount.accountByMessageLink(sender.representedObject).browser)
  end

  def checkAll(sender)
    checkAllAccounts
  end

  def checkAccount(sender)
    account = accountForGuid(sender.menu.title)
    checkerForAccount(account).reset
  end

  def showAbout(sender)
    NSApplication.sharedApplication.activateIgnoringOtherApps(true)
    NSApplication.sharedApplication.orderFrontStandardAboutPanel(sender)
  end

  def showPreferencesWindow(sender)
    NSApplication.sharedApplication.activateIgnoringOtherApps(true)
    PreferencesController.sharedController.showWindow(sender)
  end

  def donate(sender)
    NSWorkspace.sharedWorkspace.openURL(NSURL.URLWithString(DONATE_URL))
  end

  def updateMenuBarCount(notification = nil)
    msgCount = messageCount
    if GNPreferences.sharedInstance.showUnreadCount? && msgCount > 0
      @status_item.setTitle(msgCount.to_s)
    else
      @status_item.setTitle('')
    end

    if msgCount > 0
      @status_item.setToolTip(
        msgCount == 1 ? NSLocalizedString("Unread Message") % msgCount :
          NSLocalizedString("Unread Messages") % msgCount
      )
      @status_item.setImage(@mail_icon)
      @status_item.setAlternateImage(@mail_alter_icon)
    else
      @status_item.setToolTip("")
      @status_item.setImage(@app_icon)
      @status_item.setAlternateImage(@app_alter_icon)
    end
  end

  def accountAdded(notification)
    account = accountForGuid(notification.userInfo[:guid])
    addAccountMenuItem(account, GNPreferences.sharedInstance.accounts.count - 1)
    checker = GNChecker.alloc.initWithAccount(account)
    @checkers << checker
    checker.reset
  end

  def accountChanged(notification)
    account = accountForGuid(notification.userInfo[:guid])
    updateMenuItemAccountEnabled(account)
    checkerForAccount(account).reset
  end

  def accountRemoved(notification)
    item = menuItemForGuid(notification.userInfo[:guid])
    @status_item.menu.removeItem(item)
    checker = checkerForGuid(notification.userInfo[:guid])
    checker.cleanupAndQuit
    @checkers.delete(checker)
    updateMenuBarCount
  end

  def accountChecking(notification)
    #account = accountForGuid(notification.userInfo[:guid])
    @status_item.setToolTip(NSLocalizedString("Checking Mail"))
    @status_item.setImage(@check_icon)
    @status_item.setAlternateImage(@check_alter_icon)
  end

  def updateAccountMenuItem(notification)
    account = accountForGuid(notification.userInfo[:guid])
    menuItem = menuItemForAccount(account)
    menuItem.title = account.username

    count = menuItem.submenu.itemArray.count
    if count > DEFAULT_ACCOUNT_SUBMENU_COUNT
      (count - 1).downto(DEFAULT_ACCOUNT_SUBMENU_COUNT) { |idx| menuItem.submenu.removeItemAtIndex(idx) }
    end

    if account.enabled?
      checker = checkerForAccount(account)

      if checker.connectionError?
        errorItem = menuItem.submenu.addItemWithTitle(NSLocalizedString("Connection Error"), action:nil, keyEquivalent:"")
        errorItem.enabled = false
        menuItem.setImage(@error_icon)
      elsif checker.userError?
        errorItem = menuItem.submenu.addItemWithTitle(NSLocalizedString("Username/password Wrong"), action:nil, keyEquivalent:"")
        errorItem.enabled = false
        menuItem.setImage(@error_icon)
      else
        # messages list
        checker.messages.each do |msg|
          msgItem = menuItem.submenu.addItemWithTitle("#{msg[:author]}: #{msg[:subject]}", action:"openMessage:", keyEquivalent:"")
          msgItem.toolTip = msg[:summary]
          msgItem.enabled = true
          msgItem.setRepresentedObject(msg[:link])
          msgItem.target = self
        end
        menuItem.setImage(nil)
        menuItem.title = "#{account.username} (#{checker.messageCount})"
      end

      menuItem.submenu.addItem(NSMenuItem.separatorItem) if checker.messages.size > 0
      # recent check timestamp
      timeItem = menuItem.submenu.addItemWithTitle(NSLocalizedString("Last Checked:") + " #{notification.userInfo[:checkedAt]}", action:nil, keyEquivalent:"")
      timeItem.enabled = false
    end

    updateMenuBarCount
  end

  # Growl delegate
  def applicationNameForGrowl
    "Gmail Notifr"
  end

  def growlNotificationWasClicked(clickContext)
    openInboxForAccountName(clickContext, GNAccount.accountByName(clickContext).browser) if clickContext
  end

  def growlNotificationTimedOut(clickContext)
  end

  def handleMailToEvent(event, eventReply:reply)
    account = GNPreferences.sharedInstance.accounts.first
    if account
      link = event.paramDescriptorForKeyword(KeyDirectObject).stringValue
      url = account.baseurl << "?view=cm&tf=0&fs=1&to="
      url << link.split('?')[0].gsub(/mailto:/, '')
      url << "&#{link.split('?')[1]}".gsub(/&subject=/, "&su=")
      openURL(url)
    end
  end

  private

  def registerObservers
    center = NSNotificationCenter.defaultCenter
    [
      ["updateMenuBarCount:", GNShowUnreadCountChangedNotification],
      ["accountAdded:", GNAccountAddedNotification],
      ["accountChanged:", GNAccountChangedNotification],
      ["accountRemoved:", GNAccountRemovedNotification],
      ["updateAccountMenuItem:", GNAccountMenuUpdateNotification],
      ["accountChecking:", GNCheckingAccountNotification]
    ].each do |item|
      center.addObserver(self, selector:item[0], name:item[1], object:nil)
    end
  end

  def registerGrowl
    GrowlApplicationBridge.setGrowlDelegate(self)
  end

  def setupCheckers
    @checkers = []
    GNPreferences.sharedInstance.accounts.each do |a|
      @checkers << GNChecker.alloc.initWithAccount(a)
    end

    checkAllAccounts
  end

  def checkAllAccounts
    @checkers.map(&:reset)
  end

  def accountForGuid(guid)
    GNPreferences.sharedInstance.accounts.find { |a| a.guid == guid }
  end

  def checkerForAccount(account)
    @checkers.find { |c| c.forAccount?(account) }
  end

  def checkerForGuid(guid)
    @checkers.find { |c| c.forGuid?(guid) }
  end

  def messageCount
    @checkers.inject(0) { |n, c| n + c.messageCount }
  end

  def setupMenu
    GNPreferences.sharedInstance.accounts.each_with_index do |a, i|
      addAccountMenuItem(a, i)
    end
  end

  def addAccountMenuItem(account, index)
    accountMenu = NSMenu.alloc.initWithTitle(account.guid)
    accountMenu.setAutoenablesItems(false)

    #open inbox menu item
    openInboxItem = accountMenu.addItemWithTitle(NSLocalizedString("Open Inbox"), action:"openInbox:", keyEquivalent:"")
    openInboxItem.target = self
    openInboxItem.enabled = true

    #check menu item
    checkItem = accountMenu.addItemWithTitle(NSLocalizedString("Check"), action:"checkAccount:", keyEquivalent:"")
    checkItem.target = self
    checkItem.enabled = account.enabled?

    #enable/disable menu item
    enableAccountItem = accountMenu.addItemWithTitle(
      account.enabled? ? NSLocalizedString("Disable Account") : NSLocalizedString("Enable Account"),
      action:"toggleAccount:", keyEquivalent:""
    )
    enableAccountItem.target = self
    enableAccountItem.enabled = true

    accountMenu.addItem(NSMenuItem.separatorItem)

    #top level menu item for acount
    accountItem = NSMenuItem.alloc.init
    accountItem.title = account.username
    accountItem.submenu = accountMenu
    accountItem.target = self
    accountItem.action = 'openInbox:'

    @status_item.menu.insertItem(accountItem, atIndex:ACCOUNT_MENUITEM_POS + index)
  end

  def menuItemForAccount(account)
    menuItemForGuid(account.guid)
  end

  def menuItemForGuid(guid)
    @status_item.menu.itemArray.find { |i| i.submenu && i.submenu.title == guid }
  end

  def updateMenuItemAccountEnabled(account)
    menu = menuItemForAccount(account).submenu
    menu.itemAtIndex(ENABLE_MENUITEM_POS).title = account.enabled? ? NSLocalizedString("Disable Account") : NSLocalizedString("Enable Account")
    menu.itemAtIndex(CHECK_MENUITEM_POS).enabled = account.enabled?
  end

  def openInboxForAccount(account)
    openInboxForAccountName(account.username, account.customurl, account.browser)
  end

  def openInboxForAccountName(name, customurl, browserIdentifier = GNBrowser::DEFAULT)
    openURL(GNAccount.baseurl_for(name, customurl), browserIdentifier)
  end

  def registerMailtoHandler
    e = NSAppleEventManager.sharedAppleEventManager
    e.setEventHandler(self,
      andSelector:'handleMailToEvent:eventReply:',
      forEventClass:KInternetEventClass,
      andEventID:KAEGetURL
    )
  end
end

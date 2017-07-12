{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}

module Network.Wire.Bot.Email
    ( Mailbox         (mailboxSettings)
    , MailboxSettings (..)
    , MailException   (..)
    , loadMailboxConfig
    , newMailbox
    , awaitActivationMail
    , awaitPasswordResetMail
    , awaitInvitationMail
    ) where

import Codec.MIME.Parse
import Codec.MIME.Type
import Control.Concurrent
import Control.Exception
import Control.Monad (liftM2)
import Data.Aeson
import Data.Id (InvitationId)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Pool (Pool, createPool, withResource)
import Data.Text (Text)
import Data.Traversable (forM)
import Data.Typeable
import Network.HaskellNet.IMAP
import Network.HaskellNet.IMAP.Connection
import Network.HaskellNet.IMAP.SSL
import Network.Wire.Client.API.User

import qualified Data.ByteString.Lazy as LB
import qualified Data.Text            as T
import qualified Data.Text.Ascii      as Ascii
import qualified Data.Text.Encoding   as T

data MailboxSettings = MailboxSettings
    { mailboxHost        :: String
    , mailboxUser        :: Email
    , mailboxPassword    :: String
    , mailboxConnections :: Int
    }

instance FromJSON MailboxSettings where
    parseJSON = withObject "mailbox-settings" $ \o ->
        MailboxSettings <$> o .: "host"
                        <*> o .: "user"
                        <*> o .: "pass"
                        <*> o .: "conn"

data Mailbox = Mailbox
    { mailboxSettings :: MailboxSettings
    , mailboxPool     :: Pool IMAPConnection
    }

data MailException
    = MissingEmailHeaders -- ^ Missing e-mail headers needed for automation.
    | EmailTimeout        -- ^ No email received within the timeout window.
    deriving (Show, Typeable)

instance Exception MailException

loadMailboxConfig :: FilePath -> IO [Mailbox]
loadMailboxConfig p = do
    cfg <- LB.readFile p
    mbs <- either error return (eitherDecode' cfg) :: IO [MailboxSettings]
    mapM newMailbox mbs

newMailbox :: MailboxSettings -> IO Mailbox
newMailbox s@(MailboxSettings host usr pwd conns) =
    Mailbox s <$> createPool connect logout 1 60 (fromIntegral conns)
  where
    connect = do
        c <- connectIMAPSSLWithSettings host defaultSettingsIMAPSSL
        login c (show usr) pwd
        return c

-- | Awaits activation e-mail to arrive at a mailbox with
-- the designated recipient address.
awaitActivationMail :: Mailbox
                    -> Email -- ^ Expected "FROM"
                    -> Email -- ^ Expected "TO"
                    -> IO (NonEmpty (ActivationKey, ActivationCode))
awaitActivationMail mbox from to = do
    msgs <- awaitMail mbox from to "Activation"
    forM msgs $ \msg -> do
        let hdrs    = mime_val_headers msg
        let keyHdr  = find ((=="x-zeta-key")  . paramName) hdrs
        let codeHdr = find ((=="x-zeta-code") . paramName) hdrs
        case liftM2 (,) keyHdr codeHdr of
            Just (k, c) -> return $
                ( ActivationKey  $ Ascii.unsafeFromText $ paramValue k
                , ActivationCode $ Ascii.unsafeFromText $ paramValue c
                )
            Nothing -> throwIO MissingEmailHeaders

awaitPasswordResetMail :: Mailbox
                       -> Email   -- ^ Expected "FROM"
                       -> Email   -- ^ Expected "TO"
                       -> IO (NonEmpty (PasswordResetKey, PasswordResetCode))
awaitPasswordResetMail mbox from to = do
    msgs <- awaitMail mbox from to "PasswordReset"
    forM msgs $ \msg -> do
        let hdrs    = mime_val_headers msg
        let keyHdr  = find ((=="x-zeta-key")  . paramName) hdrs
        let codeHdr = find ((=="x-zeta-code") . paramName) hdrs
        case liftM2 (,) keyHdr codeHdr of
            Just (k, c) -> return $
                ( PasswordResetKey  $ Ascii.unsafeFromText $ paramValue k
                , PasswordResetCode $ Ascii.unsafeFromText $ paramValue c
                )
            Nothing -> throwIO MissingEmailHeaders

awaitInvitationMail :: Mailbox
                    -> Email   -- ^ Expected "FROM"
                    -> Email   -- ^ Expected "TO"
                    -> IO (NonEmpty InvitationId)
awaitInvitationMail mbox from to = do
    msgs <- awaitMail mbox from to "Invitation"
    forM msgs $ \msg -> do
        let hdrs   = mime_val_headers msg
        let invHdr = find ((=="x-zeta-code") . paramName) hdrs
        case invHdr of
            Just  i -> return . read . T.unpack $ paramValue i
            Nothing -> throwIO MissingEmailHeaders

awaitMail :: Mailbox
          -> Email   -- ^ Expected "FROM"
          -> Email   -- ^ Expected "TO"
          -> Text    -- ^ Expected "X-Zeta-Purpose"
          -> IO (NonEmpty MIMEValue)
awaitMail mbox from to purpose = go 0
  where
    sleep   = 5000000    -- every 5 seconds
    timeout = sleep * 24 -- for up to 2 minutes
    go t = do
        msgs <- fetchMail mbox from to purpose -- TODO: Retry on (some?) exceptions
        case msgs of
            [] | t >= timeout -> throwIO EmailTimeout
            []                -> threadDelay sleep >> go (t + sleep)
            (m:ms) -> return (m :| ms)

fetchMail :: Mailbox
          -> Email   -- ^ Expected "FROM"
          -> Email   -- ^ Expected "TO"
          -> Text    -- ^ Expected "X-Zeta-Purpose"
          -> IO [MIMEValue]
fetchMail mbox from to purpose = withResource (mailboxPool mbox) $ \c -> do
    select c "INBOX"
    msgIds <- search c [ NOTs (FLAG Seen)
                       , FROMs (T.unpack $ fromEmail from)
                       , TOs (T.unpack $ fromEmail to)
                       , HEADERs "X-Zeta-Purpose" (show purpose)
                       ]
    msgs <- mapM (fetch c) msgIds
    return $ map (parseMIMEMessage . T.decodeLatin1) msgs
{-# LANGUAGE DeriveGeneric #-} 
{-# LANGUAGE OverloadedStrings #-} 

module Model.UUID where

import           Control.Applicative ((<$>))
import           Data.Aeson
import           Data.Maybe (fromMaybe)
import           Data.String
import           Data.Text as T (pack, unpack)
import qualified Data.UUID (UUID, fromString, toString, nil, null)
import qualified Data.UUID.V4 (nextRandom)
import           GHC.Generics

newtype UUID = UUID Data.UUID.UUID
    deriving (Eq, Show, Generic)

instance FromJSON UUID where
    parseJSON = withText "UUID" $
        maybe (fail "not a UUID") (return . UUID) . Data.UUID.fromString . T.unpack

instance ToJSON UUID where
    toJSON (UUID u) = String $ T.pack $ Data.UUID.toString u

instance IsString UUID where
    fromString s = fromMaybe nil $ fromStringSafe s

fromStringSafe :: String -> Maybe UUID
fromStringSafe s = UUID <$> Data.UUID.fromString s

toString :: UUID -> String
toString (UUID u) = Data.UUID.toString u

nextRandom :: IO UUID
nextRandom = UUID <$> Data.UUID.V4.nextRandom

null :: UUID -> Bool
null (UUID u) = Data.UUID.null u

nil :: UUID
nil = UUID Data.UUID.nil


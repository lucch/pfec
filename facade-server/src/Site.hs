{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Site where
--  ( app
--  ) where

------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Monad.IO.Class
import qualified Data.ByteString.Char8     as C
import           Data.Char                 (toUpper)
import qualified Data.Configurator         as Config
import           Data.Time
import           Data.Word
import qualified Network                   as HC (withSocketsDo)
import qualified Network.HTTP.Conduit      as HC
import qualified Network.HTTP.Types.Status as HC
import           Snap
import           Snap.Internal.Http.Types
import           Snap.Types.Headers
------------------------------------------------------------------------------
import           Application
import qualified CouchDB.DBToken           as DBToken
import qualified Messages.RespFacade       as REF
import qualified Messages.RqFacade         as RQF
import qualified Model.Service             as Service
import qualified Model.Token               as Token
import           Model.URI
import qualified Model.UUID                as UUID
import           Util.HttpResponse
import           Util.JSONWebToken         (fromCompactJWT, fromB64JSON, toB64JSON)

------------------------------------------------------------------------------ | Helper function to log things into stdout.
logStdOut :: MonadIO m => C.ByteString -> m ()
logStdOut = liftIO . C.putStrLn

------------------------------------------------------------------------------ | Handler that represents the Facade Server. It acts like a front controller, interceptor and filter.
facade :: AppHandler ()
facade = do
    rq <- getRequest
    case getHeader "JWT" rq of
        Just jwtCompact -> do
            liftIO $ print jwtCompact
            (rqFacade :: Maybe RQF.RqFacade) <- liftIO $ fromB64JSON jwtCompact
            maybe badRequest handlerRqFacade rqFacade
        _ -> badRequest

------------------------------------------------------------------------------ | Handler that treats requests to Facade Server.
handlerRqFacade :: RQF.RqFacade -> AppHandler ()
handlerRqFacade (RQF.RqFacade01 contractUUID authToken) =
    (allow >>= proxify) <|> redirectToAuthServer

  where
    allow :: AppHandler Service.Service
    allow = do
        maybeToken <- liftIO $ DBToken.findToken contractUUID authToken

        token <- maybe (logStdOut "Token not found!" >> pass)
                       (\token -> logStdOut "Token found!" >> return token)
                       maybeToken

        now <- liftIO getCurrentTime
        unless ({-not (Token.wasUsed token) &&-} now < Token.expiresAt token)
               (logStdOut "Token is no longer valid!" >> pass)

        req <- getRequest
        let requestedService = if C.null (rqPathInfo req) -- Service identifier
                                   then ""
                                   else head . C.split '?' $ head . C.split '/' $ rqPathInfo req
            requestedMethod  = C.pack . show . rqMethod $ req

        unless (UUID.toByteString' (Token.serviceUUID token) == requestedService
               && requestedMethod `elem` Token.allowedMethods token)
               (logStdOut "Can't access specified service/method." >> forbidden)

        service <- liftIO $ Token.service token
        logStdOut $ C.pack $ "Service requested: " ++ show service
        return service

    proxify :: Service.Service -> AppHandler ()
    proxify service = do
        logStdOut "Proxying connection..."
        req <- getRequest
        let method' = methodToStr $ rqMethod req
            url     = show (Service.url service)
                      ++ let p = C.unpack . rqPathInfo $ req
                         in if Prelude.null p
                               then ""
                               else dropWhile (\c -> c /= '/' && c /= '?') p
                      ++ let q = C.unpack . rqQueryString $ req
                         in if Prelude.null q
                               then ""
                               else '?' : q

        logStdOut $ C.pack $ ">>> URL is: " ++ url

        respService <- liftIO $ HC.withSocketsDo $ do
            initReq <- HC.parseUrl url
            let req' = initReq { HC.checkStatus = \_ _ _ -> Nothing
                               , HC.method = method' }
            logStdOut "Sending request to the specified service..."
            --logStdOut req
            --logStdOut "---------------------------------------------------------"
            HC.withManager $ HC.httpLbs req'

        logStdOut "Received response..."
        --logStdOut respService
        --logStdOut "---------------------------------------------------------"

        -- TODO: Should we copy the information below? I mean, Headers give information
        -- about the actual server running the service...
        let resp = emptyResponse { rspHeaders = fromList $ HC.responseHeaders respService
                                 , rspStatus  = HC.statusCode $ HC.responseStatus respService
                                 , rspStatusReason = HC.statusMessage $ HC.responseStatus respService }
        putResponse resp
        writeLBS $ HC.responseBody respService

        logStdOut "Sending it back to the client..."
        --logStdOut "---------------------------------------------------------"
        getResponse >>= finishWith

      where
        methodToStr GET        = "GET"
        methodToStr POST       = "POST"
        methodToStr PUT        = "PUT"
        methodToStr DELETE     = "DELETE"
        methodToStr (Method m) = C.map toUpper m
        methodToStr _          = error "Site.hs: methodToStr: Not acceptable method."

    redirectToAuthServer :: AppHandler ()
    redirectToAuthServer = do
        logStdOut "Redirecting to Auth Server..."
        url <- gets _authServerURL
        let resp = REF.RespFacade01 {
                        REF.replyTo = url
                   }
        jwt <- liftIO $ toB64JSON resp
        let response = setHeader "JWT" jwt emptyResponse
        finishWith response

------------------------------------------------------------------------------
-- | The application's routes.
routes :: [(C.ByteString, Handler App App ())]
routes = [ ("/", facade) ]

------------------------------------------------------------------------------
-- | The application initializer.
app :: SnapletInit App App
app = makeSnaplet "facade-server" "Facade to RESTful web-services." Nothing $ do
    config <- liftIO $ Config.load [Config.Required "resources/devel.cfg"]
    url <- getAuthServerURL config
    addRoutes routes
    wrapSite (logStdOut (C.replicate 25 '-') *>)
    return $ App url
  where
    getAuthServerURL config = do
        host <- liftIO $ Config.lookupDefault "localhost" config "host"
        port :: Word16 <- liftIO $ Config.lookupDefault 8000 config "port"
        let maybeUrl = parseURI $ "https://" ++ host ++ ":" ++ show port
        maybe (error "Could not parse Auth Server's URL.") return maybeUrl


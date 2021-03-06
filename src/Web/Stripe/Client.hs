{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Web.Stripe.Client
    ( SConfig(..)
    , APIKey(..)
    , StripeResponseCode(..)
    , SFailure(..)
    , StripeError(..)
    , SErrorCode(..)
    , StripeRequest(..)
    , Stripe
    , StripeT(StripeT)
    , defaultConfig
    , runStripeT
    , baseSReq
    , query
    , queryData
    , query_

    {- Re-Export -}
    , StdMethod(..)
    ) where

import Control.Monad        ( MonadPlus, liftM, mzero, join)
import Control.Monad.Error  ( Error, ErrorT, MonadIO, MonadError, runErrorT
                            , throwError, strMsg, noMsg
                            )
import Control.Monad.State  ( MonadState, StateT, runStateT, get )
import Control.Monad.Trans  ( liftIO )
import Data.Char            ( toLower )
import Data.Text            ( Text )
        -- _TMP import Network.Curl         ( CurlOption(..), CurlResponse, CurlResponse_(..)
        -- _TMP                             , curlGetResponse_, method_GET, method_HEAD
        -- _TMP                             , method_POST
        -- _TMP                             )
import Network.HTTP.Types  --  ( StdMethod(..), renderQuery, renderStdMethod, Ascii, Request(..)
        -- _TMP import Network.URI          ( URI(..), URIAuth(..) )

import qualified Data.ByteString.Char8  as C8
import qualified Data.ByteString.Lazy   as BL
import qualified Data.ByteString        as B
import qualified Data.Text              as T
import           Network.HTTP.Conduit
import           Data.Aeson (FromJSON (..), (.:), (.:?), Value (..), decode')
import           Data.Aeson.Types (parseMaybe)
import qualified Data.HashMap.Lazy      as HML
import           Web.Stripe.Utils (textToByteString)
import           System.IO (putStrLn)

------------------------
-- General Data T\ypes --
------------------------

-- | Configuration for the 'StripeT' monad transformer.
data SConfig = SConfig
    { key    :: APIKey
    , caFile :: FilePath
    } deriving Show

-- | A key used when authenticating to the Stripe API.
newtype APIKey = APIKey { unAPIKey :: T.Text } deriving Show

-- | This represents the possible successes that a connection to the Stripe
--   API can encounter. For specificity, a success can be represented by other
--   error codes, and so the same is true in this data type.
--
--   Please consult the official Stripe REST API documentation on error codes
--   at <https://stripe.com/docs/api#errors> for more information.
data StripeResponseCode = OK | Unknown Int deriving Show

-- | This represents the possible failures that a connection to the Stripe API
--   can encounter.
--
--   Please consult the official Stripe REST API documentation on error codes
--   at <https://stripe.com/docs/api#errors> for more information.
data SFailure
    = BadRequest            (Maybe StripeError)
    | Unauthorized          (Maybe StripeError)
    | NotFound              (Maybe StripeError)
    | PaymentRequired       (Maybe StripeError)
    | InternalServerError   (Maybe StripeError)
    | BadGateway            (Maybe StripeError)
    | ServiceUnavailable    (Maybe StripeError)
    | GatewayTimeout        (Maybe StripeError)
    | OtherFailure          (Maybe Text)
    deriving Show

-- | Describes a 'SFailure' in more detail, categorizing the error and
--   providing additional information about it. At minimum, this is a message,
--   and for 'CardError', this is a message, even more precise code
--   ('SErrorCode'), and potentially a paramter that helps suggest where an
--   error message should be displayed.
--
--   In case the appropriate error could not be determined from the specified
--   type, 'UnkownError' will be returned with the supplied type and message.
--
--   Please consult the official Stripe REST API documentation on error codes
--   at <https://stripe.com/docs/api#errors> for more information.
data StripeError
    = InvalidRequestError Text
    | APIError      Text
    | CardError     Text SErrorCode (Maybe Text) -- message, code, params
    | UnknownError  Text Text  -- type, message
    deriving Show

-- | Attempts to describe a 'CardError' in more detail, classifying in what
--   specific way it failed.
--
--   Please consult the official Stripe REST API documentation on error codes
--   at <https://stripe.com/docs/api#errors> for more information.
data SErrorCode
    = InvalidNumber
    | IncorrectNumber
    | InvalidExpiryMonth
    | InvalidExpiryYear
    | InvalidCVC
    | ExpiredCard
    | InvalidAmount
    | IncorrectCVC
    | CardDeclined
    | Missing
    | DuplicateTransaction
    | ProcessingError
    | UnknownErrorCode Text -- ^ Could not be matched; text gives error name.
    deriving Show

-- | Represents a request to the Stripe API, providing the fields necessary to
--   specify a Stripe resource. More generally, 'baseSReq' will be desired as
--   it provides sensible defaults that can be overriden as needed.
data StripeRequest = StripeRequest
    { sMethod       :: StdMethod
    , sDestination  :: [Text]
    , sData         :: [(B.ByteString, B.ByteString)]
    , sQString      :: [(String, String)]
    } deriving Show

------------------
-- Stripe Monad --
------------------

-- | A convenience specialization of the 'StripeT' monad transformer in which
--   the underlying monad is IO.
type Stripe a = StripeT IO a

-- | Defines the monad transformer under which all Stripe REST API resource
--   calls take place.
newtype StripeT m a = StripeT
    { unStripeT :: StateT SConfig (ErrorT SFailure m) a
    } deriving  ( Functor, Monad, MonadIO, MonadPlus
                , MonadError SFailure
                , MonadState SConfig
                )

-- | Runs the 'StripeT' monad transformer with a given 'SConfig'. This will
--   handle all of the authorization dance steps necessary to utilize the
--   Stripe API.
--
--   Its use is demonstrated in other functions, such as 'query'.
runStripeT :: MonadIO m => SConfig -> StripeT m a -> m (Either SFailure a)
runStripeT cfg m =
    runErrorT . liftM fst . (`runStateT` cfg) . unStripeT $ m

--------------
-- Querying --
--------------

-- | Provides a default 'SConfig'. Essentially, this inserts the 'APIKey', but
--   leaves other fields blank. This is especially relavent due to the current
--   CA file check bug.
defaultConfig  :: APIKey -> SConfig
defaultConfig k = SConfig k ""

-- | The basic 'StripeRequest' environment upon which all other Stripe API requests
--   will be built. Standard usage involves overriding one or more of the
--   fields. E.g., for a request to \"https://api.stripe.com/v1/coupons\",
--   one would have:
--
-- > baseSReq { sDestinaton = ["charges"] }
baseSReq :: StripeRequest
baseSReq  = StripeRequest
    { sMethod       = GET
    , sDestination  = []
    , sData         = []
    , sQString      = []
    }

-- | Queries the Stripe API. This returns the response body along with the
--   'StripeResponseCode' undecoded. Use 'query' to try to decode it into a 'JSON'
--   type. E.g.,
--
-- > let conf = SConfig "key" "secret"
-- >
-- > runStripeT conf $
-- >    query' baseSReq { sDestination = ["charges"] }
query' :: MonadIO m => StripeRequest -> StripeT m (StripeResponseCode, BL.ByteString)
query' sReq = do
    cfg  <- get
    -- let opts' = opts $ caFile cfg
    req' <- maybe (throwError $ strMsg  "Error Prepating the Request") return (prepRq cfg sReq)
    let req = req' {checkStatus = \_ _ -> Nothing}
    -- liftIO $ print "req debug"
    -- liftIO $ print $ host req
    -- liftIO $ print $ port req
    -- liftIO $ print $ secure req
    -- liftIO $ print $ path req
    -- liftIO $ print $ queryString req
    -- _TODO we should be able to pass in a manager rather thanusing the default manager
    rsp  <- liftIO $ withManager (\mgr -> httpLbs req mgr)
    code <- toCode (responseStatus rsp) (responseBody rsp)
    -- liftIO $ putStrLn $ "---- response:"
    -- liftIO $ print $ responseBody rsp
    -- liftIO $ print $ (decode' $ responseBody rsp :: Maybe Value)
    return (code, responseBody rsp)
    --  where
    --      opts caf = CurlCAInfo caf : CurlFailOnError False : queryOptions req
    --      request  = curlGetResponse_

-- | Queries the Stripe API and attempts to parse the results into a data type
--   that is an instance of 'JSON'. This is primarily for internal use by other
--   Stripe submodules, which supply the request values accordingly. However,
--   it can also be used directly. E.g.,
--
-- > let conf = SConfig "key" "CA file"
-- >
-- > runStripeT conf $
-- >    query baseSReq { sDestination = ["charges"] }
query :: (MonadIO m, FromJSON a) => StripeRequest -> StripeT m (StripeResponseCode, a)
query req = query' req >>= \(code, ans) -> do
    maybe (throwError $ strMsg "could not parse JSON") (return . (code, )) $ decode' ans

-- | same as `query` but pulls out the value inside a data field and returns that
queryData :: (MonadIO m, FromJSON a) => StripeRequest -> StripeT m (StripeResponseCode, a)
queryData req = query' req >>= \(code, ans) -> do
    val <- maybe (throwError $ strMsg "could not parse JSON") return $ decode' ans
    case val of 
        Object o -> do
            objVal <- maybe (throwError $ strMsg "no data in json" ) return $
                            HML.lookup "data" o
            obj <- maybe (throwError $ strMsg "parsed JSON didn't contain object") return $
                        parseMaybe parseJSON objVal
            return (code, obj)
        _ -> throwError $ strMsg "JSON was not object"

-- | Acts just like 'query', but on success, throws away the response. Errors
--   contacting the Stripe API will still be reported.
query_ :: MonadIO m => StripeRequest -> StripeT m ()
query_ req = query' req >> return ()

setUserAgent :: Ascii -> Request m -> Request m
setUserAgent ua req = req { requestHeaders = ("User-Agent", ua) : filteredHeaders }
  where
    filteredHeaders = filter ((/= "User-Agent") . fst) $ requestHeaders req

-- | Transforms a 'StripeRequest' into a more general 'URI', which can be used to
--   make an authenticated query to the Stripe server.
--   _TODO there is lots of sloppy Text <-> String stuff here.. should fix
prepRq :: Monad m => SConfig -> StripeRequest -> Maybe (Request m)
prepRq cfg sReq = flip fmap mReq $ \req -> applyBasicAuth k p $ 
    (addBodyUa req) { queryString = renderQuery False qs 
                    , method = renderStdMethod $ sMethod sReq
                    }
  where
    k = textToByteString . unAPIKey $ key cfg
    p = textToByteString ""
    addBodyUa = urlEncodedBody (sData sReq) . setUserAgent "hs-string/0.2 http-conduit" 
    mReq = parseUrl . T.unpack $ T.concat 
            [ "https://api.stripe.com:443/v1/"
            , T.intercalate "/" (sDestination sReq) ] 
    qs  = map (\(a, b) -> (C8.pack a, Just $ C8.pack b)) $ sQString sReq

--------------------
-- Error Handling --
--------------------

-- | Given an HTTP status code and the response body as input, this function
--   determines whether or not the status code represents an error as
--   per Stripe\'s REST API documentation. If it does, 'SFailure' is thrown as
--   an error. Otherwise, 'StripeResponseCode' is returned, representing the status
--   of the request.
--
--   If an error is encountered, this function will attempt to decode the
--   response body with 'errorMsg' to retrieve (and return) an explanation with
--   the 'SFailure'.
toCode :: Monad m => Status -> BL.ByteString -> StripeT m StripeResponseCode
toCode c body = case statusCode c of
    -- Successes
    200 -> return OK
    -- Failures
    400 -> throwError $ BadRequest e
    401 -> throwError $ Unauthorized e
    404 -> throwError $ NotFound e
    402 -> throwError $ PaymentRequired e
    500 -> throwError $ InternalServerError e
    502 -> throwError $ BadGateway e
    503 -> throwError $ ServiceUnavailable e
    504 -> throwError $ GatewayTimeout e
    -- Unknown; assume success
    i   -> return $ Unknown i
  where e = errorMsg body

-- | Converts a 'String'-represented error code into the 'SErrorCode' data
--   type to more descriptively classify errors.
--
--   If the string does not represent a known error code, 'UnknownErrorCode'
--   will be returned with the raw text representing the error code.
toCECode :: T.Text -> SErrorCode
toCECode c = case T.map toLower c of
    "invalid_number"        -> InvalidNumber
    "incorrect_number"      -> IncorrectNumber
    "invalid_expiry_month"  -> InvalidExpiryMonth
    "invalid_expiry_year"   -> InvalidExpiryYear
    "invalid_cvc"           -> InvalidCVC
    "expired_card"          -> ExpiredCard
    "invalid_amount"        -> InvalidAmount
    "incorrect_cvc"         -> IncorrectCVC
    "card_declined"         -> CardDeclined
    "missing"               -> Missing
    "duplicate_transaction" -> DuplicateTransaction
    "processing_error"      -> ProcessingError
    _                       -> UnknownErrorCode c

-- | This function attempts to decode the contents of a response body as JSON
--   and retrieve an error message in an \"error\" field. E.g.,
--
-- >>> errorMsg "{\"error\":\"Oh no, an error!\"}"
-- Just "Oh no, an error!"
errorMsg :: BL.ByteString -> Maybe StripeError
errorMsg bs = join $ flip fmap (decode' bs) getErrorVal
  where
    getErrorVal (Object o) = maybe Nothing (parseMaybe  parseJSON) (HML.lookup "error" o)
    getErrorVal _ = Nothing

-- | Attempts to parse error information provided with each error by the Stripe
--   API. In the parsing, the error is classified as a specific 'StripeError' and
--   any useful data, such as a message explaining the error, is extracted
--   accordingly.
instance FromJSON StripeError where
    parseJSON (Object err) = do
        type_ <- err .: "type"
        msg   <- err .: "message"
        case T.map toLower type_ of
            "invalid_request_error" -> return $ InvalidRequestError msg
            "api_error"  -> return $ APIError msg
            "card_error" -> do
                code  <- err .: "code"
                param <- err .:? "param"
                return $ CardError msg (toCECode code) param
            _ -> return $ UnknownError type_ msg
    parseJSON _ = mzero

-- | Defines the behavior for more general error messages that can be thrown
--   with 'noMsg' and 'strMsg' in combination with 'throwError'.
instance Error SFailure where
    noMsg  = OtherFailure Nothing
    strMsg = OtherFailure . Just . T.pack

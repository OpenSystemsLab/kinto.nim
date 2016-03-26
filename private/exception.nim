import httpclient

type
  KintoException* = object of Exception
    ## Errors returned by server
    response*: httpclient.Response
      ## responsed packet

  BucketNotFoundException* = KintoException
    ## Bucket not found or not accessible

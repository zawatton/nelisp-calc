#ifndef UNICODE
#define UNICODE
#endif
#define _UNICODE
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <propkey.h>
#include <stdio.h>
#include <wchar.h>

/* A stable GUI-subsystem entry point; backend ownership stays in launch.ps1. */
static const wchar_t *modes[] = {L"standard",L"scientific",L"programmer",L"graph",L"date",L"convert",L"currency"};
static const wchar_t *titles[] = {L"標準",L"関数電卓",L"プログラマー",L"グラフ",L"日付の計算",L"単位換算",L"通貨換算"};
static wchar_t executable[32768], root[32768], appid[129];
static HRESULT property(IPropertyStore *store, const PROPERTYKEY *key, const wchar_t *value) {
    PROPVARIANT v; ZeroMemory(&v,sizeof(v)); v.vt=VT_LPWSTR; v.pwszVal=(LPWSTR)value;
    return IPropertyStore_SetValue(store,key,&v);
}
static HRESULT link(const wchar_t *args, const wchar_t *title, const wchar_t *save, IShellLinkW **out) {
    IShellLinkW *s=NULL; IPropertyStore *p=NULL; IPersistFile *f=NULL;
    HRESULT hr=CoCreateInstance(&CLSID_ShellLink,NULL,CLSCTX_INPROC_SERVER,&IID_IShellLinkW,(void**)&s);
    if (SUCCEEDED(hr)) hr=IShellLinkW_SetPath(s,executable);
    if (SUCCEEDED(hr)) hr=IShellLinkW_SetArguments(s,args);
    if (SUCCEEDED(hr)) hr=IShellLinkW_SetWorkingDirectory(s,root);
    if (SUCCEEDED(hr)) hr=IShellLinkW_SetIconLocation(s,executable,0);
    if (SUCCEEDED(hr)) hr=IShellLinkW_QueryInterface(s,&IID_IPropertyStore,(void**)&p);
    if (SUCCEEDED(hr)) hr=property(p,&PKEY_Title,title);
    if (SUCCEEDED(hr)) hr=property(p,&PKEY_AppUserModel_ID,appid);
    if (SUCCEEDED(hr)) hr=IPropertyStore_Commit(p);
    if (p) IPropertyStore_Release(p);
    if (SUCCEEDED(hr) && save) {
        hr=IShellLinkW_QueryInterface(s,&IID_IPersistFile,(void**)&f);
        if (SUCCEEDED(hr)) hr=IPersistFile_Save(f,save,TRUE);
        if (f) IPersistFile_Release(f);
    }
    if (SUCCEEDED(hr) && out) *out=s; else if (s) IShellLinkW_Release(s);
    return hr;
}
static HRESULT tasks(const wchar_t *directory) {
    ICustomDestinationList *list=NULL; IObjectCollection *collection=NULL; IObjectArray *removed=NULL,*array=NULL;
    UINT slots=0; BOOL begun=FALSE; HRESULT hr=S_OK;
    if (!directory) {
        hr=CoCreateInstance(&CLSID_DestinationList,NULL,CLSCTX_INPROC_SERVER,&IID_ICustomDestinationList,(void**)&list);
        if (SUCCEEDED(hr)) hr=ICustomDestinationList_SetAppID(list,appid);
        if (SUCCEEDED(hr)) hr=ICustomDestinationList_BeginList(list,&slots,&IID_IObjectArray,(void**)&removed);
        if (SUCCEEDED(hr)) begun=TRUE;
    }
    if (SUCCEEDED(hr)) hr=CoCreateInstance(&CLSID_EnumerableObjectCollection,NULL,CLSCTX_INPROC_SERVER,&IID_IObjectCollection,(void**)&collection);
    for (int i=0;i<7 && SUCCEEDED(hr);i++) {
        wchar_t args[96],path[32768]; IShellLinkW *s=NULL;
        swprintf(args,96,L"--mode %ls",modes[i]);
        if (directory) swprintf(path,32768,L"%ls\\%ls.lnk",directory,modes[i]);
        hr=link(args,titles[i],directory?path:NULL,&s);
        if (SUCCEEDED(hr)) { hr=IObjectCollection_AddObject(collection,(IUnknown*)s); IShellLinkW_Release(s); }
    }
    if (SUCCEEDED(hr) && !directory) hr=IObjectCollection_QueryInterface(collection,&IID_IObjectArray,(void**)&array);
    if (SUCCEEDED(hr) && !directory) hr=ICustomDestinationList_AddUserTasks(list,array);
    if (SUCCEEDED(hr) && !directory) { hr=ICustomDestinationList_CommitList(list); if (SUCCEEDED(hr)) begun=FALSE; }
    if (begun) ICustomDestinationList_AbortList(list);
    if (array) IObjectArray_Release(array);
    if (removed) IObjectArray_Release(removed);
    if (collection) IObjectCollection_Release(collection);
    if (list) ICustomDestinationList_Release(list);
    return hr;
}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE previous,LPWSTR command,int show) {
    (void)instance;(void)previous;(void)command;(void)show;
    int argc=0; LPWSTR *argv=CommandLineToArgvW(GetCommandLineW(),&argc);
    const wchar_t *mode=L"standard"; BOOL hidden=GetEnvironmentVariableW(L"NELISP_CALC_HIDDEN",NULL,0)>0; HRESULT hr;
    if (!argv) return 2;
    if (!GetModuleFileNameW(NULL,executable,32768)) return 3;
    wcscpy(root,executable); wchar_t *slash=wcsrchr(root,L'\\'); if (!slash) return 3; *slash=0;
    wchar_t probe[32768]; swprintf(probe,32768,L"%ls\\tools\\emacs-launch.ps1",root);
    if(GetFileAttributesW(probe)==INVALID_FILE_ATTRIBUTES) {
        swprintf(probe,32768,L"%ls\\app\\tools\\emacs-launch.ps1",root);
        if(GetFileAttributesW(probe)!=INVALID_FILE_ATTRIBUTES) wcscat(root,L"\\app");
        else {slash=wcsrchr(root,L'\\');if(!slash)return 3;*slash=0;}
    }
    DWORD n=GetEnvironmentVariableW(L"NELISP_CALC_APP_ID",appid,129);
    if (!n) wcscpy(appid,L"Fujisawa.NeLispCalc");
    if (n>=129 || wcschr(appid,L' ')) return 2;
    hr=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return 4;
    SetCurrentProcessExplicitAppUserModelID(appid);
    if (argc==2 && !wcscmp(argv[1],L"--register")) hr=tasks(NULL);
    else if (argc==3 && !wcscmp(argv[1],L"--shortcut")) hr=link(L"",L"NeLisp Calc",argv[2],NULL);
    else if (argc==3 && !wcscmp(argv[1],L"--export-tasks")) hr=tasks(argv[2]);
    else {
        BOOL seen=FALSE;
        for (int i=1;i<argc;i++) {
            if (!wcscmp(argv[i],L"--mode") && !seen && i+1<argc) {mode=argv[++i];seen=TRUE;}
            else if (!wcscmp(argv[i],L"--hidden")) hidden=TRUE;
            else {CoUninitialize();LocalFree(argv);return 2;}
        }
        int valid=0; for(int i=0;i<7;i++) if(!wcscmp(mode,modes[i])) valid=1;
        if (!valid) {CoUninitialize();LocalFree(argv);return 2;}
        wchar_t script[32768], ps[32768], code[65536];
        swprintf(script,32768,L"%ls\\tools\\emacs-launch.ps1",root);
        /* Windows file names cannot contain quotes; mode is allowlisted above. */
        DWORD size=GetEnvironmentVariableW(L"SystemRoot",ps,32768);
        if (!size || size>32000) return 3;
        wcscat(ps,L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
        swprintf(code,65536,L"\"%ls\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%ls\" -ProjectRoot \"%ls\"%ls%ls%ls",ps,script,root,seen?L" -Mode ":L"",seen?mode:L"",hidden?L" -Hidden":L" -Activate");
        STARTUPINFOW si; PROCESS_INFORMATION pi; ZeroMemory(&si,sizeof(si)); si.cb=sizeof(si);si.dwFlags=STARTF_USESHOWWINDOW;si.wShowWindow=SW_HIDE;
        hr=CreateProcessW(ps,code,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,root,&si,&pi)?S_OK:HRESULT_FROM_WIN32(GetLastError());
        if(SUCCEEDED(hr)){CloseHandle(pi.hThread);CloseHandle(pi.hProcess);}
    }
    CoUninitialize(); LocalFree(argv); return FAILED(hr)?(int)hr:0;
}
